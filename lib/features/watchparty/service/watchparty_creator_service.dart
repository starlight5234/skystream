import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import '../../settings/presentation/general_settings_provider.dart';
import 'watchparty_connection_service.dart';
import 'webrtc_connection_manager.dart';
import 'watchparty_crypto.dart';
import 'watchparty_message_broker.dart';

class WatchPartyCreatorService extends WatchPartyConnectionService {
  bool _lobbyReady = false;
  StreamSubscription<Map<String, dynamic>?>? _lobbySubscription;
  Timer? _pollTimer;
  String? _activeHostName;
  String? _roomPasscode;

  final Map<String, RTCPeerConnection> activeConnections = {};
  final Map<String, RTCDataChannel> activeDataChannels = {};
  final Set<String> _pendingGuests = {};
  late final WatchPartyMessageBroker messageBroker;

  void Function(String guestName, RTCDataChannel channel)? onGuestConnected;
  void Function(String guestName)? onGuestDisconnected;

  WatchPartyCreatorService(super.settings, super.database) {
    messageBroker = WatchPartyMessageBroker(activeDataChannels);
    messageBroker.onGuestTimeout = (guestName) {
      logMessage('Guest "$guestName" keep-alive timed out. Disconnecting...');
      _disconnectGuest(guestName);
    };
    messageBroker.onGuestLeaveRequest = (guestName) {
      logMessage('Guest "$guestName" requested to leave. Disconnecting...');
      _disconnectGuest(guestName);
    };
  }

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

    statusMessage = 'Initializing database room...';
    logMessage('Host session started by user: "$hostName" (passcode: "$_roomPasscode")');

    try {
      if (!database.isConfigured()) {
        throw Exception('Database configuration is invalid.');
      }

      // Determine device limit based on platform
      final isDesktop = !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux);
      final maxGuests = isDesktop ? 5 : 1;
      final deviceType = isDesktop ? 'PC' : 'Mobile';
      final passcodeHash = WatchPartyCrypto.hashPasscode(_roomPasscode!, hostName);

      // Create room in database
      await database.createLobby(
        hostName: hostName,
        deviceType: deviceType,
        maxGuests: maxGuests,
        passcodeHash: passcodeHash,
      );

      logMessage('Lobby created successfully on database. Key: $hostName (Max Guests: $maxGuests)');

      // Transition to chat screen immediately
      _lobbyReady = true;
      isLoading = false;
      notifyListeners();

      // Begin listening for guest offers in the background
      logMessage('Subscribing to database lobby for guest offers...');
      _lobbySubscription = database.subscribeToLobby(hostName: hostName).listen((row) {
        if (row == null) return;
        final signaling = _parseSignaling(row['signaling']);
        if (signaling.isNotEmpty) {
          _processGuestOffers(signaling);
        }
      });

      // Periodic polling fallback
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        try {
          if (_lobbySubscription == null || error != null) {
            timer.cancel();
            return;
          }
          final row = await database.getLobby(hostName: hostName);
          if (row != null && _lobbySubscription != null) {
            final signaling = _parseSignaling(row['signaling']);
            if (signaling.isNotEmpty) {
              _processGuestOffers(signaling);
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

  void _processGuestOffers(List<dynamic> signaling) {
    if (signaling.isEmpty) return;

    for (final rawItem in signaling) {
      final guestData = Map<String, dynamic>.from(rawItem as Map);
      final encryptedOffer = guestData['guest_offer'] as String;
      final guestName = guestData['guest_name'] as String;
      final hostAnswer = guestData['host_answer'] as String?;

      if (hostAnswer != null) continue;
      if (activeConnections.containsKey(guestName) || _pendingGuests.contains(guestName)) continue;

      _pendingGuests.add(guestName);
      logMessage('Guest offer received from "$guestName". Processing connection in background...');

      unawaited(Future(() async {
        try {
          final guestOfferSdp = WatchPartyCrypto.decrypt(encryptedOffer, _roomPasscode!, _activeHostName!);
          logMessage('Initializing PeerConnection for guest "$guestName"...');

          final pc = await WebRTCConnectionManager.createConnection(settings, logCallback: logMessage);
          activeConnections[guestName] = pc;
          _setupGuestConnectionListeners(guestName, pc);

          pc.onDataChannel = (dc) {
            logMessage('Data channel received from guest: "$guestName"');
            activeDataChannels[guestName] = dc;
            messageBroker.registerGuest(guestName, dc);

            dc.onDataChannelState = (state) {
              final strState = state.toString().split('.').last;
              logMessage('Guest data channel state for "$guestName" changed to: $strState');
              if (state == RTCDataChannelState.RTCDataChannelClosed) {
                _disconnectGuest(guestName);
              }
            };

            onGuestConnected?.call(guestName, dc);
            notifyListeners();
          };

          logMessage('Setting remote description (Guest Offer) for "$guestName"...');
          await pc.setRemoteDescription(RTCSessionDescription(guestOfferSdp, 'offer'));

          logMessage('Creating local SDP answer for "$guestName"...');
          final answer = await pc.createAnswer({
            'mandatory': {
              'OfferToReceiveAudio': false,
              'OfferToReceiveVideo': false,
            },
            'optional': [],
          });

          logMessage('Setting local description (Answer) for "$guestName"...');
          await pc.setLocalDescription(answer);

          logMessage('Waiting for local ICE candidate gathering for "$guestName"...');
          await _waitForGuestIceGatheringCompletion(pc);

          final localDesc = await pc.getLocalDescription();
          final fullSdp = localDesc?.sdp ?? answer.sdp;

          logMessage('Encrypting and writing SDP answer for "$guestName" to database...');
          final encryptedAnswer = WatchPartyCrypto.encrypt(fullSdp!, _roomPasscode!, _activeHostName!);
          await database.respondToLobby(
            hostName: _activeHostName!,
            guestName: guestName,
            sdpAnswer: encryptedAnswer,
          );
          logMessage('SDP answer registered successfully for "$guestName".');
        } catch (e) {
          logMessage('ERROR handshaking with guest "$guestName": $e');
          _disconnectGuest(guestName);
        } finally {
          _pendingGuests.remove(guestName);
        }
      }));
    }
  }

  Future<void> _waitForGuestIceGatheringCompletion(RTCPeerConnection pc) async {
    if (pc.iceGatheringState == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final completer = Completer<void>();
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        if (!completer.isCompleted) completer.complete();
      }
    };
    await completer.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  void kickGuest(String guestName) {
    logMessage('Kicking guest: "$guestName"');
    final dc = activeDataChannels[guestName];
    if (dc != null) {
      try {
        final jsonMsg = jsonEncode({'type': 'control', 'action': 'kick'});
        dc.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}
    }
    _disconnectGuest(guestName);
  }

  void _disconnectGuest(String guestName) {
    if (!activeConnections.containsKey(guestName) && !activeDataChannels.containsKey(guestName)) {
      return;
    }
    logMessage('Disconnecting guest: "$guestName"');
    final pc = activeConnections.remove(guestName);
    final dc = activeDataChannels.remove(guestName);

    unawaited(dc?.close());
    unawaited(pc?.dispose());

    unawaited(database.leaveLobby(hostName: _activeHostName!, guestName: guestName).catchError((_) {}));

    messageBroker.unregisterGuest(guestName);
    onGuestDisconnected?.call(guestName);
    notifyListeners();
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

  void _setupGuestConnectionListeners(String guestName, RTCPeerConnection pc) {
    pc.onIceConnectionState = (state) {
      final strState = state.toString().split('.').last;
      logMessage('ICE connection state for "$guestName" changed to: $strState');
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _disconnectGuest(guestName);
      }
    };

    pc.onSignalingState = (state) {
      final strState = state.toString().split('.').last;
      logMessage('Signaling state for "$guestName" changed to: $strState');
    };

    pc.onIceGatheringState = (state) {
      final strState = state.toString().split('.').last;
      logMessage('ICE gathering state for "$guestName" changed to: $strState');
    };

    pc.onIceCandidate = (candidate) {
      if (candidate == null) {
        logMessage('ICE candidate gathering complete for "$guestName"');
        return;
      }
      final cand = candidate.candidate ?? '';
      String type = 'unknown';
      if (cand.contains('typ host')) {
        type = 'host (Local)';
      } else if (cand.contains('typ srflx')) {
        type = 'srflx (NAT)';
      } else if (cand.contains('typ relay')) {
        type = 'relay (TURN)';
      }
      logMessage('ICE candidate gathered for "$guestName": $type');
    };
  }

  @override
  void cleanup() {
    if (_activeHostName != null && _roomPasscode != null) {
      final hash = WatchPartyCrypto.hashPasscode(_roomPasscode!, _activeHostName!);
      unawaited(database.deleteLobby(hostName: _activeHostName!, passcodeHash: hash).catchError((_) {}));
    }
    if (_lobbySubscription != null) {
      unawaited(_lobbySubscription!.cancel());
      _lobbySubscription = null;
    }
    _pollTimer?.cancel();
    _pollTimer = null;

    for (final dc in activeDataChannels.values) {
      unawaited(dc.close());
    }
    activeDataChannels.clear();

    for (final pc in activeConnections.values) {
      unawaited(pc.dispose());
    }
    activeConnections.clear();
    _pendingGuests.clear();
    messageBroker.clear();

    super.cleanup();
  }

  @override
  void dispose() {
    messageBroker.dispose();
    super.dispose();
  }
}
