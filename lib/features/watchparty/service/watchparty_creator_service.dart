import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import '../../settings/presentation/general_settings_provider.dart';
import 'watchparty_connection_service.dart';
import 'webrtc_connection_manager.dart';
import 'watchparty_crypto.dart';

class WatchPartyCreatorService extends WatchPartyConnectionService {
  bool _lobbyReady = false;
  StreamSubscription<Map<String, dynamic>?>? _lobbySubscription;
  Timer? _pollTimer;
  String? _activeHostName;
  String? _roomPasscode;

  WatchPartyCreatorService(super.settings, super.database);

  bool get lobbyReady => _lobbyReady;
  String? get roomPasscode => _roomPasscode;

  Future<void> startHosting(String hostName, {String? customPasscode}) async {
    resetState();
    isLoading = true;
    _lobbyReady = false;
    _activeHostName = hostName;

    if (customPasscode != null && customPasscode.trim().isNotEmpty) {
      _roomPasscode = customPasscode.trim();
    } else {
      _roomPasscode = WatchPartyCrypto.generatePasscode();
    }

    statusMessage = 'Initializing WebRTC connection...';
    logMessage('Host session started by user: "$hostName" (passcode: "$_roomPasscode")');

    try {
      if (!database.isConfigured()) {
        throw Exception('Database configuration is invalid.');
      }

      // 1. Create PeerConnection
      logMessage('Initializing PeerConnection...');
      final config = WebRTCConnectionManager.getIceConfiguration(settings);
      logMessage('ICE Server list size: ${(config['iceServers'] as List<dynamic>).length}');
      logMessage('TURN Username: ${settings.watchPartyTurnUsername.isNotEmpty ? settings.watchPartyTurnUsername : "NONE (Bypassed)"}');
      
      final pc = await WebRTCConnectionManager.createConnection(settings, logCallback: logMessage);
      if (!isLoading) {
        unawaited(pc.dispose());
        return;
      }
      peerConnection = pc;
      setupConnectionListeners(pc);

      // 2. Host creates DataChannel
      logMessage('Creating data channel "chat"...');
      final dcInit = RTCDataChannelInit()..binaryType = 'text';
      final dc = await pc.createDataChannel('chat', dcInit);
      if (!isLoading || peerConnection == null) {
        unawaited(dc.close());
        return;
      }
      dataChannel = dc;
      setupDataChannelListeners(dc);
      logMessage('Data channel "chat" initialized.');

      // 3. Create Offer
      logMessage('Creating SDP offer...');
      final offer = await pc.createOffer({
        'mandatory': {
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': false,
        },
        'optional': [],
      });
      if (!isLoading || peerConnection == null) return;
      
      logMessage('Setting local description (offer)...');
      await pc.setLocalDescription(offer);
      if (!isLoading || peerConnection == null) return;

      // 4. Wait for ICE candidate gathering
      statusMessage = 'Gathering network paths...';
      logMessage('Waiting for ICE candidate gathering...');
      await waitForIceGatheringCompletion();
      if (!isLoading || peerConnection == null) return;

      final localDesc = await pc.getLocalDescription();
      if (!isLoading || peerConnection == null) return;
      final fullSdp = localDesc?.sdp ?? offer.sdp;
      logSdpDiagnostics(fullSdp!, 'Local');

      // 5. Upload to database
      statusMessage = 'Creating room on database...';
      logMessage('Encrypting SDP offer and uploading to database lobby...');
      final encryptedOffer = WatchPartyCrypto.encrypt(fullSdp, _roomPasscode!, hostName);
      await database.createLobby(
        hostName: hostName,
        deviceType: 'Mobile',
        maxGuests: 1,
        sdpOffer: encryptedOffer,
      );
      if (!isLoading || peerConnection == null) {
        // Cancelled while database write was in flight; teardown database lobby
        unawaited(database.deleteLobby(hostName: hostName).catchError((_) {}));
        return;
      }
      logMessage('Lobby created successfully. Key: $hostName');

      // 6. Listen for guest answers
      statusMessage = 'Waiting for guest to join...';
      _lobbyReady = true;
      notifyListeners();
      logMessage('Subscribing to database lobby for answers...');

      _lobbySubscription = database.subscribeToLobby(hostName: hostName).listen((row) {
        if (row == null) return;
        logMessage('Lobby database update received.');
        final answers = _parseSdpAnswers(row['sdp_answers']);
        logMessage('Lobby sdp_answers count: ${answers.length}');
        if (answers.isNotEmpty) {
          _processGuestAnswer(answers);
        }
      });

      // 6b. 2-second periodic polling fallback (since WebSocket connection can be flaky on cellular networks)
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        try {
          if (_lobbySubscription == null || peerConnection == null || connectionSuccess || error != null) {
            timer.cancel();
            return;
          }
          final row = await database.getLobby(hostName: hostName);
          if (row != null && _lobbySubscription != null) {
            final answers = _parseSdpAnswers(row['sdp_answers']);
            if (answers.isNotEmpty) {
              logMessage('[Poll] Guest answer detected via database polling fallback.');
              _processGuestAnswer(answers);
            }
          }
        } catch (e) {
          logMessage('[Poll] Polling fallback error: $e');
        }
      });

    } catch (e) {
      logMessage('ERROR in host creation: $e');
      if (isLoading) {
        final cleanMsg = e.toString().replaceFirst('Exception: ', '');
        error = cleanMsg;
        cleanup();
      }
    }
  }

  void _processGuestAnswer(List<dynamic> answers) {
    if (answers.isEmpty) return;

    final guestData = Map<String, dynamic>.from(answers.first as Map);
    final encryptedAnswer = guestData['answer'] as String;
    final guestName = guestData['guestName'] as String;
    logMessage('Guest answer received from user: "$guestName". Decrypting...');

    String guestAnswer;
    try {
      guestAnswer = WatchPartyCrypto.decrypt(encryptedAnswer, _roomPasscode!, _activeHostName!);
    } catch (e) {
      logMessage('Warning: Failed to decrypt SDP answer from guest "$guestName". Ignoring.');
      return;
    }

    // Cancel database listening and polling now that valid guest answer is parsed
    _lobbySubscription?.cancel();
    _lobbySubscription = null;
    _pollTimer?.cancel();
    _pollTimer = null;

    logSdpDiagnostics(guestAnswer, 'Remote');

    statusMessage = 'Establishing Peer connection...';

    final pc = peerConnection;
    if (pc == null) return;

    logMessage('Setting remote description (Guest Answer)...');
    unawaited(pc.setRemoteDescription(RTCSessionDescription(guestAnswer, 'answer')).then((_) {
      logMessage('Remote description set successfully. Starting ICE negotiation...');
    }).catchError((e) {
      logMessage('ERROR setting remote description: $e');
      error = 'Connection failed: remote description mismatch.';
      cleanup();
    }));

    // Start 60-second connection timeout
    unawaited(Future.delayed(const Duration(seconds: 60), () {
      if (isLoading && !connectionSuccess && error == null) {
        logMessage('ICE Connection Timeout (60s) reached.');
        
        // Clean up database row since connection timed out
        if (_activeHostName != null) {
          unawaited(database.deleteLobby(hostName: _activeHostName!).catchError((_) {}));
        }

        final summary = getFailureSummary();
        logMessage(summary);

        error = 'Connection timed out. Router firewall blocked P2P.\n\n'
            'Please verify your TURN server configuration credentials in settings if you are connecting across separate networks.\n\n'
            '$summary';
        cleanup();
      }
    }));
  }

  Future<void> cancelHosting() async {
    if (_activeHostName != null) {
      await database.deleteLobby(hostName: _activeHostName!);
    }
    cleanup();
    isLoading = false;
    _lobbyReady = false;
    connectionSuccess = false;
    notifyListeners();
  }

  List<dynamic> _parseSdpAnswers(dynamic raw) {
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

  @override
  void cleanup() {
    if (_activeHostName != null && !connectionSuccess) {
      unawaited(database.deleteLobby(hostName: _activeHostName!).catchError((_) {}));
    }
    if (_lobbySubscription != null) {
      unawaited(_lobbySubscription!.cancel());
      _lobbySubscription = null;
    }
    _pollTimer?.cancel();
    _pollTimer = null;
    super.cleanup();
  }
}
