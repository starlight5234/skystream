import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import '../../settings/presentation/general_settings_provider.dart';
import 'watchparty_connection_service.dart';
import 'webrtc_connection_manager.dart';
import 'watchparty_crypto.dart';

class WatchPartyJoinerService extends WatchPartyConnectionService {
  String? _activeHostName;
  String? _activeGuestName;

  WatchPartyJoinerService(super.settings, super.database);

  Future<void> startJoining(String hostName, String guestName, String passcode) async {
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

      // 1. Fetch Host Offer
      logMessage('Fetching host SDP offer from database...');
      final lobby = await database.getLobby(hostName: hostName);
      if (!isLoading) return;
      if (lobby == null) {
        throw Exception('Lobby not found.');
      }

      final encryptedOffer = lobby['sdp_offer'] as String;
      logMessage('Decrypting host SDP offer...');
      final hostOffer = WatchPartyCrypto.decrypt(encryptedOffer, passcode, hostName);
      logMessage('Host Offer decrypted successfully.');
      logSdpDiagnostics(hostOffer, 'Remote');

      // 2. Create PeerConnection
      logMessage('Creating PeerConnection...');
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

      // 3. Guest listens to host's data channel
      logMessage('Listening for host data channel...');
      pc.onDataChannel = (dc) {
        logMessage('Data channel received from host.');
        dataChannel = dc;
        setupDataChannelListeners(dc);
      };

      // 4. Set Host Offer as Remote Description
      logMessage('Setting remote description (Host Offer)...');
      await pc.setRemoteDescription(RTCSessionDescription(hostOffer, 'offer'));
      if (!isLoading || peerConnection == null) return;
      logMessage('Remote description set successfully.');

      // 5. Create Guest Answer
      logMessage('Creating SDP answer...');
      final answer = await pc.createAnswer({
        'mandatory': {
          'OfferToReceiveAudio': false,
          'OfferToReceiveVideo': false,
        },
        'optional': [],
      });
      if (!isLoading || peerConnection == null) return;
      
      logMessage('Setting local description (answer)...');
      await pc.setLocalDescription(answer);
      if (!isLoading || peerConnection == null) return;

      // 6. Wait for ICE candidate gathering
      statusMessage = 'Gathering guest network paths...';
      logMessage('Waiting for local ICE candidate gathering...');
      await waitForIceGatheringCompletion();
      if (!isLoading || peerConnection == null) return;

      final localDesc = await pc.getLocalDescription();
      if (!isLoading || peerConnection == null) return;
      final fullSdp = localDesc?.sdp ?? answer.sdp;
      logSdpDiagnostics(fullSdp!, 'Local');

      // 7. Write Answer to database
      statusMessage = 'Registering with host...';
      logMessage('Encrypting and uploading SDP answer to database...');
      final encryptedAnswer = WatchPartyCrypto.encrypt(fullSdp, passcode, hostName);
      await database.joinLobby(
        hostName: hostName,
        guestName: guestName,
        sdpAnswer: encryptedAnswer,
      );
      if (!isLoading || peerConnection == null) return;
      logMessage('SDP answer registered successfully.');

      statusMessage = 'Negotiating connection...';
      logMessage('Lobby handshake complete. Negotiating ICE connection...');
      notifyListeners();

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
      final cleanMsg = e.toString().replaceFirst('Exception: ', '');
      error = cleanMsg;
      cleanup();
    }
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
    super.cleanup();
  }
}
