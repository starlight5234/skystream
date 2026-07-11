import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import '../../settings/presentation/general_settings_provider.dart';
import 'watchparty_connection_service.dart';
import 'webrtc_connection_manager.dart';
import 'watchparty_crypto.dart';

class WatchPartyJoinerService extends WatchPartyConnectionService {
  String? _activeHostName;
  String? _activeGuestName;
  StreamSubscription<Map<String, dynamic>?>? _lobbySubscription;
  Timer? _pollTimer;

  WatchPartyJoinerService(super.settings, super.database);

  Future<void> startJoining(
    String hostName,
    String guestName,
    String passcode, {
    String? customTurnUsername,
    String? customTurnPassword,
  }) async {
    resetState();
    isLoading = true;
    _activeHostName = hostName;
    _activeGuestName = guestName;

    statusMessage = 'Joining lobby...';
    logMessage('Join session started for guest "$guestName" joining host "$hostName" with passcode');

    try {
      if (!database.isConfigured()) {
        throw Exception('Database configuration is invalid.');
      }

      // 1. Fetch Host Lobby to verify its existence
      logMessage('Verifying host lobby on database...');
      final lobby = await database.getLobby(hostName: hostName);
      if (!isLoading) return;
      if (lobby == null) {
        throw Exception('Lobby not found.');
      }

      // 2. Create PeerConnection
      logMessage('Creating PeerConnection...');
      final config = WebRTCConnectionManager.getIceConfiguration(
        settings,
        customTurnUsername: customTurnUsername,
        customTurnPassword: customTurnPassword,
      );
      logMessage('ICE Server list size: ${(config['iceServers'] as List<dynamic>).length}');
      logMessage('TURN Username: ${(customTurnUsername ?? settings.watchPartyTurnUsername).isNotEmpty ? (customTurnUsername ?? settings.watchPartyTurnUsername) : "NONE (Bypassed)"}');
      
      final pc = await WebRTCConnectionManager.createConnection(
        settings,
        customTurnUsername: customTurnUsername,
        customTurnPassword: customTurnPassword,
        logCallback: logMessage,
      );
      if (!isLoading) {
        unawaited(pc.dispose());
        return;
      }
      peerConnection = pc;
      setupConnectionListeners(pc);

      // 3. Guest creates the DataChannel locally so it is negotiated in the SDP offer
      logMessage('Creating data channel "chat" (Guest-Initiated)...');
      final dcInit = RTCDataChannelInit()..binaryType = 'text';
      final dc = await pc.createDataChannel('chat', dcInit);
      if (!isLoading || peerConnection == null) {
        unawaited(dc.close());
        return;
      }
      dataChannel = dc;
      setupDataChannelListeners(dc);
      logMessage('Data channel "chat" initialized.');

      // 4. Create SDP offer
      logMessage('Creating local SDP offer...');
      final offer = await pc.createOffer({
        'mandatory': {
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': false,
        },
        'optional': [],
      });
      if (!isLoading || peerConnection == null) return;
      
      logMessage('Setting local description (Offer)...');
      await pc.setLocalDescription(offer);
      if (!isLoading || peerConnection == null) return;

      // 5. Wait for ICE candidate gathering
      statusMessage = 'Gathering guest network paths...';
      logMessage('Waiting for local ICE candidate gathering...');
      await waitForIceGatheringCompletion();
      if (!isLoading || peerConnection == null) return;

      final localDesc = await pc.getLocalDescription();
      if (!isLoading || peerConnection == null) return;
      final fullSdp = localDesc?.sdp ?? offer.sdp;
      logSdpDiagnostics(fullSdp!, 'Local');

      // 6. Write Offer to database signaling queue
      statusMessage = 'Registering with host...';
      logMessage('Encrypting and uploading SDP offer to database...');
      final encryptedOffer = WatchPartyCrypto.encrypt(fullSdp, passcode, hostName);
      final passcodeHash = WatchPartyCrypto.hashPasscode(passcode, hostName);
      await database.joinLobby(
        hostName: hostName,
        guestName: guestName,
        sdpOffer: encryptedOffer,
        passcodeHash: passcodeHash,
      );
      if (!isLoading || peerConnection == null) return;
      logMessage('SDP offer registered successfully.');

      // 7. Subscribe to database lobby and wait for Host Answer
      statusMessage = 'Waiting for host response...';
      logMessage('Subscribing to database lobby for host answer...');

      _lobbySubscription = database.subscribeToLobby(hostName: hostName).listen((row) {
        if (row == null) return;
        final signaling = _parseSignaling(row['signaling']);
        if (signaling.isNotEmpty) {
          _processHostAnswer(signaling, passcode);
        }
      });

      // 7b. Polling fallback
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        try {
          if (_lobbySubscription == null || peerConnection == null || connectionSuccess || error != null) {
            timer.cancel();
            return;
          }
          final row = await database.getLobby(hostName: hostName);
          if (row != null && _lobbySubscription != null) {
            final signaling = _parseSignaling(row['signaling']);
            if (signaling.isNotEmpty) {
              _processHostAnswer(signaling, passcode);
            }
          }
        } catch (e) {
          logMessage('[Poll] Polling fallback error: $e');
        }
      });

      // Start 60-second connection timeout
      unawaited(Future.delayed(const Duration(seconds: 60), () {
        if (isLoading && !connectionSuccess && error == null) {
          logMessage('ICE Connection Timeout (60s) reached.');
          final summary = getFailureSummary();
          logMessage(summary);
          error = 'Connection timed out. Router firewall blocked P2P.\n\n'
              'Please verify your TURN server configuration credentials in settings if you are connecting across separate networks.\n\n'
              '$summary';
          cleanup();
        }
      }));

    } catch (e) {
      logMessage('ERROR in handshake: $e');
      String cleanMsg = e.toString();
      if (cleanMsg.contains('lobby is full')) {
        cleanMsg = 'This watch party lobby is full.';
      } else {
        cleanMsg = cleanMsg.replaceFirst('Exception: ', '');
      }
      error = cleanMsg;
      cleanup();
    }
  }

  void _processHostAnswer(List<dynamic> signaling, String passcode) {
    // Find the signaling entry for this specific guest
    final entry = signaling.firstWhere(
      (element) => Map<String, dynamic>.from(element as Map)['guest_name'] == _activeGuestName,
      orElse: () => null,
    );

    if (entry == null) return;

    final guestData = Map<String, dynamic>.from(entry as Map);
    final encryptedAnswer = guestData['host_answer'] as String?;

    // If host hasn't answered yet, keep waiting
    if (encryptedAnswer == null) return;

    logMessage('Host answer received. Decrypting...');

    String hostAnswerSdp;
    try {
      hostAnswerSdp = WatchPartyCrypto.decrypt(encryptedAnswer, passcode, _activeHostName!);
    } catch (e) {
      logMessage('Warning: Failed to decrypt SDP answer from host. Ignoring.');
      return;
    }

    // Cancel database listening and polling now that valid host answer is parsed
    _lobbySubscription?.cancel();
    _lobbySubscription = null;
    _pollTimer?.cancel();
    _pollTimer = null;

    logSdpDiagnostics(hostAnswerSdp, 'Remote');
    statusMessage = 'Negotiating connection...';

    final pc = peerConnection;
    if (pc == null) return;

    logMessage('Setting remote description (Host Answer)...');
    unawaited(pc.setRemoteDescription(RTCSessionDescription(hostAnswerSdp, 'answer')).then((_) {
      logMessage('Remote description set successfully. Starting ICE negotiation...');
      notifyListeners();
    }).catchError((e) {
      logMessage('ERROR setting remote description: $e');
      error = 'Connection failed: remote description mismatch.';
      cleanup();
    }));
  }

  void cancelJoining() {
    cleanup();
    isLoading = false;
    connectionSuccess = false;
    notifyListeners();
  }

  @override
  void cleanup() {
    if (_activeHostName != null && _activeGuestName != null && !connectionSuccess) {
      unawaited(database.leaveLobby(
        hostName: _activeHostName!,
        guestName: _activeGuestName!,
      ).catchError((_) {}));
    }
    if (_lobbySubscription != null) {
      unawaited(_lobbySubscription!.cancel());
      _lobbySubscription = null;
    }
    _pollTimer?.cancel();
    _pollTimer = null;
    super.cleanup();
  }

  List<dynamic> _parseSignaling(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded;
      } catch (_) {}
    }
    return [];
  }
}
