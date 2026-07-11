import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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

      // 2. Set up Data Channel listener (Guest initiates data channel creation)
      pc.onDataChannel = (dc) {
        logMessage('Data channel received from guest.');
        dataChannel = dc;
        setupDataChannelListeners(dc);
      };

      // 3. Upload lobby structure to Supabase
      statusMessage = 'Creating room on database...';
      logMessage('Creating database lobby (Guest-Initiated)...');
      
      // Determine device limit based on platform
      final isDesktop = !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux);
      final maxGuests = isDesktop ? 5 : 1;
      final deviceType = isDesktop ? 'PC' : 'Mobile';

      final passcodeHash = WatchPartyCrypto.hashPasscode(_roomPasscode!, hostName);

      await database.createLobby(
        hostName: hostName,
        deviceType: deviceType,
        maxGuests: maxGuests,
        passcodeHash: passcodeHash,
      );
      if (!isLoading || peerConnection == null) {
        unawaited(database.deleteLobby(hostName: hostName, passcodeHash: passcodeHash).catchError((_) {}));
        return;
      }
      logMessage('Lobby created successfully. Key: $hostName (Max Guests: $maxGuests)');

      // 4. Listen for guest offers
      statusMessage = 'Waiting for guest to join...';
      _lobbyReady = true;
      notifyListeners();
      logMessage('Subscribing to database lobby for offers...');

      _lobbySubscription = database.subscribeToLobby(hostName: hostName).listen((row) {
        if (row == null) return;
        final signaling = _parseSignaling(row['signaling']);
        if (signaling.isNotEmpty) {
          _processGuestOffer(signaling);
        }
      });

      // 4b. Periodic polling fallback
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
              _processGuestOffer(signaling);
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

  void _processGuestOffer(List<dynamic> signaling) {
    if (signaling.isEmpty) return;

    // Handle the first guest offer in the array
    final guestData = Map<String, dynamic>.from(signaling.first as Map);
    final encryptedOffer = guestData['guest_offer'] as String;
    final guestName = guestData['guest_name'] as String;
    final hostAnswer = guestData['host_answer'] as String?;

    // If we've already answered this guest, skip processing to avoid loops
    if (hostAnswer != null) return;

    logMessage('Guest offer received from user: "$guestName". Decrypting...');

    String guestOfferSdp;
    try {
      guestOfferSdp = WatchPartyCrypto.decrypt(encryptedOffer, _roomPasscode!, _activeHostName!);
    } catch (e) {
      logMessage('Warning: Failed to decrypt SDP offer from guest "$guestName". Ignoring.');
      return;
    }

    // Cancel database listening and polling now that valid guest offer is parsed
    _lobbySubscription?.cancel();
    _lobbySubscription = null;
    _pollTimer?.cancel();
    _pollTimer = null;

    logSdpDiagnostics(guestOfferSdp, 'Remote');
    statusMessage = 'Answering guest handshake...';

    final pc = peerConnection;
    if (pc == null) return;

    unawaited(Future(() async {
      try {
        logMessage('Setting remote description (Guest Offer)...');
        await pc.setRemoteDescription(RTCSessionDescription(guestOfferSdp, 'offer'));
        if (!isLoading || peerConnection == null) return;

        logMessage('Creating local SDP answer...');
        final answer = await pc.createAnswer({
          'mandatory': {
            'OfferToReceiveAudio': false,
            'OfferToReceiveVideo': false,
          },
          'optional': [],
        });
        if (!isLoading || peerConnection == null) return;

        logMessage('Setting local description (Answer)...');
        await pc.setLocalDescription(answer);
        if (!isLoading || peerConnection == null) return;

        // Wait for ICE candidate gathering
        logMessage('Waiting for local ICE candidate gathering...');
        await waitForIceGatheringCompletion();
        if (!isLoading || peerConnection == null) return;

        final localDesc = await pc.getLocalDescription();
        if (!isLoading || peerConnection == null) return;
        final fullSdp = localDesc?.sdp ?? answer.sdp;
        logSdpDiagnostics(fullSdp!, 'Local');

        // Write answer back to database signaling queue
        logMessage('Encrypting and writing SDP answer to database signaling queue...');
        final encryptedAnswer = WatchPartyCrypto.encrypt(fullSdp, _roomPasscode!, _activeHostName!);
        await database.respondToLobby(
          hostName: _activeHostName!,
          guestName: guestName,
          sdpAnswer: encryptedAnswer,
        );
        logMessage('SDP answer registered successfully.');
        statusMessage = 'Negotiating connection...';
        notifyListeners();

        // Start 60-second connection timeout
        unawaited(Future.delayed(const Duration(seconds: 60), () {
          if (isLoading && !connectionSuccess && error == null) {
            logMessage('ICE Connection Timeout (60s) reached.');
            if (_activeHostName != null && _roomPasscode != null) {
              final hash = WatchPartyCrypto.hashPasscode(_roomPasscode!, _activeHostName!);
              unawaited(database.deleteLobby(hostName: _activeHostName!, passcodeHash: hash).catchError((_) {}));
            }
            final summary = getFailureSummary();
            logMessage(summary);
            error = 'Connection timed out. Router firewall blocked P2P.\n\n'
                'Please verify your TURN server configuration credentials in settings if you are connecting across separate networks.\n\n'
                '$summary';
            cleanup();
          }
        }));

      } catch (e) {
        logMessage('ERROR in generating answer handshake: $e');
        error = 'Handshake failed: $e';
        cleanup();
      }
    }));
  }

  Future<void> cancelHosting() async {
    if (_activeHostName != null && _roomPasscode != null) {
      final hash = WatchPartyCrypto.hashPasscode(_roomPasscode!, _activeHostName!);
      await database.deleteLobby(hostName: _activeHostName!, passcodeHash: hash);
    }
    cleanup();
    isLoading = false;
    _lobbyReady = false;
    connectionSuccess = false;
    notifyListeners();
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

  @override
  void cleanup() {
    if (_activeHostName != null && _roomPasscode != null && !connectionSuccess) {
      final hash = WatchPartyCrypto.hashPasscode(_roomPasscode!, _activeHostName!);
      unawaited(database.deleteLobby(hostName: _activeHostName!, passcodeHash: hash).catchError((_) {}));
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
