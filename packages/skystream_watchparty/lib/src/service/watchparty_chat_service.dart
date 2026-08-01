import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../config/watchparty_settings.dart';
import '../data/watchparty_database.dart';
import 'watchparty_creator_service.dart';
import 'watchparty_joiner_service.dart';

class WatchPartyChatService extends ChangeNotifier with WidgetsBindingObserver {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  final WatchPartyCreatorService? _creatorService;
  WatchPartyJoinerService? _joinerService;
  final WatchPartyDatabase _database;
  final bool _isHost;
  final String _hostName;
  String _userName;
  final String _passcode;

  final List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _outboxQueue = [];
  bool _connectionClosed = false;
  bool _isReconnecting = false;
  int _reconnectAttempts = 0;
  bool _isHandshakeInFlight = false;
  Timer? _backoffTimer;
  String? _kickMessage;
  StreamSubscription<Map<String, dynamic>?>? _lobbyDbSubscription;
  VoidCallback? onAllGuestsLeft;
  void Function(String guestName)? onGuestConnected;
  void Function(String requesterName)? onSyncStateRequested;
  void Function(int positionMs, bool isPlaying)? onSyncStateReceived;
  void Function(String cmd, int positionMs)? onPlayerCommandReceived;
  
  Timer? _keepAliveTimer;
  DateTime _lastSeen = DateTime.now();

  WatchPartyChatService({
    RTCPeerConnection? peerConnection,
    RTCDataChannel? dataChannel,
    WatchPartyCreatorService? creatorService,
    WatchPartyJoinerService? joinerService,
    required WatchPartyDatabase database,
    required bool isHost,
    required String hostName,
    required String userName,
    required String passcode,
  })  : _peerConnection = peerConnection,
        _dataChannel = dataChannel,
        _creatorService = creatorService,
        _joinerService = joinerService,
        _database = database,
        _isHost = isHost,
        _hostName = hostName,
        _userName = userName,
        _passcode = passcode {
    WidgetsBinding.instance.addObserver(this);
    if (_isHost) {
      _setupHostListeners();
    } else {
      _setupGuestListeners();
    }
  }

  bool _isAppBackgrounded = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isAppBackgrounded = true;
    } else if (state == AppLifecycleState.resumed) {
      _isAppBackgrounded = false;
      _lastSeen = DateTime.now();
      _onAppResumed();
    }
  }

  void _onAppResumed() {
    if (_isHost || _connectionClosed) return;
    final isChannelOpen = _dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen;
    if (!isChannelOpen && !_isReconnecting && !_isHandshakeInFlight) {
      _backoffTimer?.cancel();
      _backoffTimer = null;
      _isReconnecting = true;
      notifyListeners();
      _attemptReconnection();
    } else if (isChannelOpen) {
      _lastSeen = DateTime.now();
      _flushOutbox();
    }
  }

  /// Nulls out all event callbacks on the current peer/channel before
  /// re-assigning them to a new connection. This prevents stale closed-channel
  /// events on a disposed peer from launching phantom reconnect attempts.
  void _clearGuestChannelCallbacks() {
    _peerConnection?.onIceConnectionState = null;
    _dataChannel?.onMessage = null;
    _dataChannel?.onDataChannelState = null;
  }

  List<Map<String, dynamic>> get messages {
    if (_isHost && _creatorService != null) {
      return _creatorService!.messageBroker.messages;
    }
    return _messages;
  }

  bool get connectionClosed => _connectionClosed;
  String? get kickMessage => _kickMessage;
  bool get isReconnecting => _isReconnecting;
  int get reconnectAttempts => _reconnectAttempts;

  void _setupHostListeners() {
    if (_creatorService == null) return;

    _creatorService!.messageBroker.addListener(_onBrokerUpdated);

    _creatorService!.onGuestConnected = (guestName, dc) {
      onGuestConnected?.call(guestName);
      notifyListeners();
    };

    _creatorService!.messageBroker.onSyncStateRequested = (requester) {
      onSyncStateRequested?.call(requester);
    };

    _creatorService!.messageBroker.onSyncStateReceived = (pos, playing) {
      onSyncStateReceived?.call(pos, playing);
    };

    _creatorService!.messageBroker.onPlayerCommandReceived = (cmd, pos) {
      onPlayerCommandReceived?.call(cmd, pos);
    };

    _creatorService!.onGuestDisconnected = (guestName) {
      if (_creatorService!.activeDataChannels.isEmpty) {
        onAllGuestsLeft?.call();
      }
    };

    _creatorService!.addListener(_onCreatorServiceUpdated);
  }

  void _onCreatorServiceUpdated() {
    if (_creatorService?.error != null) {
      _connectionClosed = true;
      _kickMessage = _creatorService!.error;
      notifyListeners();
    }
  }

  void _onBrokerUpdated() {
    notifyListeners();
  }

  void _setupGuestListeners() {
    if (_dataChannel == null) return;

    // Always clear callbacks on the old channel objects before assigning
    // new ones. Without this, a disposed peer's stale ICE disconnect event
    // can fire _attemptReconnection() concurrently with a live reconnect.
    _clearGuestChannelCallbacks();

    _lastSeen = DateTime.now();
    _startGuestKeepAliveTimer();

    _dataChannel!.onMessage = (message) {
      try {
        final decoded = jsonDecode(message.text) as Map<String, dynamic>;
        final type = decoded['type'] as String;

        if (type == 'control') {
          final action = decoded['action'] as String;
          if (action == 'ping') {
            _lastSeen = DateTime.now();
            final jsonMsg = jsonEncode({'type': 'control', 'action': 'pong'});
            try {
              _dataChannel?.send(RTCDataChannelMessage(jsonMsg));
            } catch (_) {}
          } else if (action == 'pong') {
            _lastSeen = DateTime.now();
          } else if (action == 'peer_disconnected') {
            final guest = decoded['guest'] as String? ?? 'A peer';
            _addSystemMessage('$guest has left the watch party');
          } else if (action == 'host_ended') {
            _connectionClosed = true;
            _isReconnecting = false;
            _kickMessage = 'The host has ended the watch party.';
            notifyListeners();
            return;
          } else if (action == 'kick') {
            _connectionClosed = true;
            _isReconnecting = false;
            _kickMessage = 'You have been kicked from the watch party by the host.';
            notifyListeners();
            return;
          } else if (action == 'assigned_name') {
            final newName = decoded['name'] as String?;
            if (newName != null && newName.isNotEmpty) {
              _userName = newName;
              _addSystemMessage('Your display name in this lobby was set to "$newName".');
              notifyListeners();
            }
          } else if (action == 'msg_ack') {
            _lastSeen = DateTime.now();
            final msgId = decoded['msgId'] as String?;
            if (msgId != null) {
              for (final msg in _messages) {
                if (msg['msgId'] == msgId) {
                  msg['status'] = 'sent';
                  break;
                }
              }
              _outboxQueue.removeWhere((item) => item['msgId'] == msgId);
              notifyListeners();
            }
          } else if (action == 'get_sync_state') {
            final requester = decoded['requester'] as String? ?? 'Friend';
            onSyncStateRequested?.call(requester);
          } else if (action == 'sync_state_response') {
            final positionMs = decoded['positionMs'] as int? ?? 0;
            final isPlaying = decoded['isPlaying'] as bool? ?? false;
            onSyncStateReceived?.call(positionMs, isPlaying);
          } else if (action == 'player_command') {
            final cmd = decoded['cmd'] as String? ?? 'ping';
            final positionMs = decoded['positionMs'] as int? ?? 0;
            onPlayerCommandReceived?.call(cmd, positionMs);
          }
          return;
        }

        if (type == 'media_card') {
          _lastSeen = DateTime.now();
          final mediaPayload = decoded['media'] as Map<String, dynamic>?;
          final sender = decoded['sender'] as String? ?? 'Friend';
          final msgId = decoded['msgId'] as String?;
          if (mediaPayload != null) {
            _addDeduplicatedMessage({
              'type': 'media_card',
              'msgId': msgId,
              'sender': sender,
              'media': mediaPayload,
              'isMe': sender == _userName,
              'time': DateTime.now(),
            });
          }
        } else if (type == 'chat') {
          _lastSeen = DateTime.now();
          final text = decoded['text'] as String;
          final sender = decoded['sender'] as String? ?? 'Friend';
          final msgId = decoded['msgId'] as String?;
          _addDeduplicatedMessage({
            'type': 'chat',
            'msgId': msgId,
            'text': text,
            'sender': sender,
            'isMe': sender == _userName,
            'time': DateTime.now(),
          });
        }
      } catch (_) {
        _lastSeen = DateTime.now();
        _addDeduplicatedMessage({
          'type': 'chat',
          'text': message.text,
          'sender': 'Friend',
          'isMe': false,
          'time': DateTime.now(),
        });
      }
    };

    _peerConnection?.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        if (!_connectionClosed && !_isReconnecting && !_isHandshakeInFlight) {
          _backoffTimer?.cancel();
          _backoffTimer = null;
          _isReconnecting = true;
          notifyListeners();
          _attemptReconnection();
        }
      }
    };

    _dataChannel!.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        // Immediately clear reconnecting state the instant the new channel opens.
        // This makes the UI banner disappear in sync with the Host seeing 'X joined'
        // instead of lagging 1-5s behind the reconnect() Future.
        if (_isReconnecting) {
          _isReconnecting = false;
          _reconnectAttempts = 0;
          _backoffTimer?.cancel();
          _backoffTimer = null;
          notifyListeners();
        }
        _flushOutbox();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        if (!_connectionClosed && !_isReconnecting && !_isHandshakeInFlight) {
          _backoffTimer?.cancel();
          _backoffTimer = null;
          _isReconnecting = true;
          notifyListeners();
          _attemptReconnection();
        } else if (_connectionClosed) {
          notifyListeners();
        }
      }
    };

    // If the channel is already open at the point of calling _setupGuestListeners()
    // (e.g. immediately after a successful reconnect()), the onDataChannelState
    // callback above won't fire. Clear _isReconnecting here directly.
    if (_dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen && _isReconnecting) {
      _isReconnecting = false;
      _reconnectAttempts = 0;
      notifyListeners();
      _flushOutbox();
    }

    _setupDbListener();
  }

  Future<void> _attemptReconnection() async {
    if (_isHandshakeInFlight || _connectionClosed) return;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _isHandshakeInFlight = true;
    _isReconnecting = true;
    _reconnectAttempts++;
    notifyListeners();

    try {
      // Verify the lobby exists before attempting WebRTC handshake.
      // On phone wake, the first REST call may fail due to socket init — catch and proceed.
      try {
        final lobby = await _database.getLobby(hostName: _hostName);
        if (lobby == null) {
          // Double-check after 1s to rule out transient socket error on phone wake
          await Future<void>.delayed(const Duration(seconds: 1));
          final recheck = await _database.getLobby(hostName: _hostName);
          if (recheck == null) {
            _connectionClosed = true;
            _isReconnecting = false;
            _kickMessage = 'The host has ended the watch party.';
            notifyListeners();
            return;
          }
        }
      } catch (_) {
        // Transient network error on wake — continue with reconnect attempt
      }

      if (_joinerService == null && !_isHost) {
        final loadedSettings = await WatchPartySettings.loadFromPrefs();
        _joinerService = WatchPartyJoinerService(loadedSettings, _database);
      }

      final joiner = _joinerService;
      if (joiner == null) {
        _connectionClosed = true;
        _kickMessage = 'Reconnection failed: Joiner service is unavailable.';
        _isReconnecting = false;
        notifyListeners();
        return;
      }

      final success = await joiner.reconnect(
        hostName: _hostName,
        guestName: _userName,
        passcode: _passcode,
      );

      if (success) {
        _peerConnection = joiner.peerConnection;
        _dataChannel = joiner.dataChannel;
        _reconnectAttempts = 0;
        _lastSeen = DateTime.now();
        _setupGuestListeners();
        _flushOutbox();
        if (_messages.isEmpty || _messages.last['text'] != 'Reconnected to host.') {
          _addSystemMessage('Reconnected to host.');
        }
        notifyListeners();
      } else {
        // Handshake failed. Verify lobby still exists before retrying.
        bool lobbyExists = true;
        try {
          final lobby = await _database.getLobby(hostName: _hostName);
          if (lobby == null) {
            lobbyExists = false;
            _connectionClosed = true;
            _isReconnecting = false;
            _kickMessage = 'The host has ended the watch party.';
            notifyListeners();
            return;
          }
        } catch (_) {
          // Network still unstable — assume lobby exists and keep trying
        }

        if (lobbyExists && !_connectionClosed) {
          // Exponential backoff: 2s, 4s, 8s, 16s, capped at 30s
          final backoffSeconds = _reconnectAttempts <= 1 ? 2
              : _reconnectAttempts == 2 ? 4
              : _reconnectAttempts == 3 ? 8
              : _reconnectAttempts == 4 ? 16
              : 30;
          notifyListeners();
          _backoffTimer?.cancel();
          _backoffTimer = Timer(Duration(seconds: backoffSeconds), () {
            _backoffTimer = null;
            if (!_connectionClosed && !_isHandshakeInFlight) {
              _attemptReconnection();
            }
          });
        }
      }
    } catch (_) {
      // Unexpected exception — keep _isReconnecting true so UI shows banner
      // and user can tap "Retry Now"
    } finally {
      _isHandshakeInFlight = false;
    }
  }

  void manualRetryReconnect() {
    if (_connectionClosed) return;
    // If a handshake is actively in-flight with the host (WebRTC/DB negotiating),
    // debounce and do NOT cancel/interrupt it to prevent out-of-sync race conditions.
    if (_isHandshakeInFlight) return;

    // If we were sleeping in exponential backoff, cancel the sleep timer immediately!
    _backoffTimer?.cancel();
    _backoffTimer = null;

    _reconnectAttempts = 0;
    _isReconnecting = true;
    notifyListeners();
    _attemptReconnection();
  }

  void _startGuestKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 8), (timer) {
      if (_connectionClosed || _dataChannel == null) {
        timer.cancel();
        return;
      }

      if (_dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
        try {
          final pingMsg = jsonEncode({'type': 'control', 'action': 'ping'});
          _dataChannel!.send(RTCDataChannelMessage(pingMsg));
        } catch (_) {}
      }

      if (!_isAppBackgrounded && DateTime.now().difference(_lastSeen) > const Duration(seconds: 60)) {
        if (!_isReconnecting && !_isHandshakeInFlight && !_connectionClosed) {
          _backoffTimer?.cancel();
          _backoffTimer = null;
          _isReconnecting = true;
          notifyListeners();
          _attemptReconnection();
        }
      }
    });
  }

  void _setupDbListener() {
    // Cancel any pre-existing subscription before creating a new one.
    // Without this, every reconnect cycle would stack up an additional
    // Supabase subscription that could fire spurious "Watch Party Ended" events.
    if (_lobbyDbSubscription != null) {
      unawaited(_lobbyDbSubscription!.cancel());
      _lobbyDbSubscription = null;
    }

    _lobbyDbSubscription = _database.subscribeToLobby(hostName: _hostName).listen((row) async {
      if (row == null) {
        // Double-check via REST after 1.5s to distinguish a genuine host-delete
        // from a transient WebSocket stream drop (phone sleep/network switch).
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        try {
          final recheck = await _database.getLobby(hostName: _hostName);
          if (recheck != null) {
            // Lobby still exists — ignore the transient stream drop
            return;
          }
        } catch (_) {
          // Network unavailable — assume lobby still exists, don't close
          return;
        }

        if (!_connectionClosed) {
          _connectionClosed = true;
          _isReconnecting = false;
          _kickMessage = 'The host has ended the watch party.';
          notifyListeners();
        }
      }
    });
  }

  void _addDeduplicatedMessage(Map<String, dynamic> item) {
    final msgId = item['msgId'] as String?;
    final text = item['text'] as String?;
    final sender = item['sender'] as String?;

    if (msgId != null && msgId.isNotEmpty) {
      final exists = _messages.any((m) => m['msgId'] == msgId);
      if (exists) return;
    } else if (text != null && sender != null) {
      final exists = _messages.any((m) =>
          m['sender'] == sender &&
          m['text'] == text &&
          DateTime.now().difference((m['time'] as DateTime? ?? DateTime.now())).inSeconds < 3);
      if (exists) return;
    }

    _messages.add(item);
    notifyListeners();
  }

  void _addSystemMessage(String text) {
    _messages.add({
      'type': 'system',
      'text': text,
      'time': DateTime.now(),
    });
    notifyListeners();
  }

  void _flushOutbox() {
    if (_outboxQueue.isEmpty) return;
    if (_dataChannel == null || _dataChannel!.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }

    final sentItems = <Map<String, dynamic>>[];
    for (final item in List<Map<String, dynamic>>.from(_outboxQueue)) {
      try {
        final text = item['text'] as String? ?? '';
        final type = item['type'] as String? ?? 'chat';
        final msgId = item['msgId'] as String? ?? '';

        if (type == 'media_card') {
          final media = item['media'] as Map<String, dynamic>? ?? {};
          final payload = {
            'type': 'media_card',
            'msgId': msgId,
            'sender': _userName,
            'media': media,
          };
          _dataChannel!.send(RTCDataChannelMessage(jsonEncode(payload)));
        } else {
          final payload = {
            'type': 'chat',
            'msgId': msgId,
            'sender': _userName,
            'text': text,
          };
          _dataChannel!.send(RTCDataChannelMessage(jsonEncode(payload)));
        }
        sentItems.add(item);
      } catch (_) {
        break;
      }
    }
    if (sentItems.isNotEmpty) {
      _outboxQueue.removeWhere((item) => sentItems.contains(item));
    }
  }

  void sendMediaCard(Map<String, dynamic> mediaPayload) {
    final msgId = '${DateTime.now().millisecondsSinceEpoch}_${_messages.length}';

    final messageItem = {
      'type': 'media_card',
      'msgId': msgId,
      'sender': _userName,
      'media': mediaPayload,
      'isMe': true,
      'time': DateTime.now(),
      'status': 'sending',
    };

    _messages.add(messageItem);

    if (_isHost) {
      if (_creatorService != null) {
        _creatorService!.messageBroker.broadcastMediaCard(_userName, mediaPayload);
        messageItem['status'] = 'sent';
      }
      notifyListeners();
      return;
    }

    _outboxQueue.add(messageItem);

    final isChannelOpen = _dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen &&
        !_isReconnecting;

    if (isChannelOpen) {
      try {
        final jsonMsg = jsonEncode({
          'type': 'media_card',
          'msgId': msgId,
          'sender': _userName,
          'media': mediaPayload,
        });
        _dataChannel!.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {
        if (!_isReconnecting && !_isHandshakeInFlight) {
          _backoffTimer?.cancel();
          _backoffTimer = null;
          _isReconnecting = true;
          notifyListeners();
          _attemptReconnection();
        }
      }
    } else if (!_isReconnecting && !_isHandshakeInFlight) {
      _backoffTimer?.cancel();
      _backoffTimer = null;
      _isReconnecting = true;
      notifyListeners();
      _attemptReconnection();
    }

    // Unacknowledged timeout fallback
    Future<void>.delayed(const Duration(seconds: 25), () {
      if (messageItem['status'] == 'sending' && !_connectionClosed && hasListeners) {
        messageItem['status'] = 'failed';
        notifyListeners();
      }
    });

    notifyListeners();
  }

  void requestSyncState() {
    final payload = {
      'type': 'control',
      'action': 'get_sync_state',
      'requester': _userName,
    };
    if (_isHost && _creatorService != null) {
      _creatorService!.messageBroker.broadcastRawJson(payload);
    } else if (_dataChannel != null && _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        _dataChannel!.send(RTCDataChannelMessage(jsonEncode(payload)));
      } catch (_) {}
    }
  }

  void sendSyncStateResponse(int positionMs, bool isPlaying) {
    final payload = {
      'type': 'control',
      'action': 'sync_state_response',
      'positionMs': positionMs,
      'isPlaying': isPlaying,
    };
    if (_isHost && _creatorService != null) {
      _creatorService!.messageBroker.broadcastRawJson(payload);
    } else if (_dataChannel != null && _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        _dataChannel!.send(RTCDataChannelMessage(jsonEncode(payload)));
      } catch (_) {}
    }
  }

  void sendPlayerCommand(String cmd, int positionMs) {
    final payload = {
      'type': 'control',
      'action': 'player_command',
      'cmd': cmd,
      'positionMs': positionMs,
    };
    if (_isHost && _creatorService != null) {
      _creatorService!.messageBroker.broadcastRawJson(payload);
    } else if (_dataChannel != null && _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      try {
        _dataChannel!.send(RTCDataChannelMessage(jsonEncode(payload)));
      } catch (_) {}
    }
  }

  void sendMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final msgId = '${DateTime.now().millisecondsSinceEpoch}_${_messages.length}';

    final messageItem = {
      'type': 'chat',
      'msgId': msgId,
      'text': trimmed,
      'sender': _userName,
      'isMe': true,
      'time': DateTime.now(),
      'status': 'sending',
    };

    _messages.add(messageItem);

    if (_isHost) {
      if (_creatorService != null) {
        _creatorService!.messageBroker.broadcastChatMessage(_userName, trimmed);
        messageItem['status'] = 'sent';
      }
      notifyListeners();
      return;
    }

    _outboxQueue.add(messageItem);

    final isChannelOpen = _dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen &&
        !_isReconnecting;

    if (isChannelOpen) {
      try {
        final jsonMsg = jsonEncode({
          'type': 'chat',
          'msgId': msgId,
          'sender': _userName,
          'text': trimmed,
        });
        _dataChannel!.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {
        if (!_isReconnecting && !_isHandshakeInFlight) {
          _backoffTimer?.cancel();
          _backoffTimer = null;
          _isReconnecting = true;
          notifyListeners();
          _attemptReconnection();
        }
      }
    } else if (!_isReconnecting && !_isHandshakeInFlight) {
      _backoffTimer?.cancel();
      _backoffTimer = null;
      _isReconnecting = true;
      notifyListeners();
      _attemptReconnection();
    }

    // Unacknowledged timeout fallback
    Future<void>.delayed(const Duration(seconds: 25), () {
      if (messageItem['status'] == 'sending' && !_connectionClosed && hasListeners) {
        messageItem['status'] = 'failed';
        notifyListeners();
      }
    });

    notifyListeners();
  }

  Future<void> leaveParty() async {
    if (_isHost) {
      if (_creatorService != null) {
        await _creatorService!.cancelHosting();
      }
    } else {
      if (_dataChannel != null) {
        try {
          final jsonMsg = jsonEncode({'type': 'control', 'action': 'leave'});
          _dataChannel!.send(RTCDataChannelMessage(jsonMsg));
        } catch (_) {}
      }
      try {
        await _database.leaveLobby(hostName: _hostName, guestName: _userName);
      } catch (_) {}
      _cleanup();
    }
  }

  void _cleanup() {
    _clearGuestChannelCallbacks();
    _connectionClosed = true;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _isHandshakeInFlight = false;
    if (_lobbyDbSubscription != null) {
      unawaited(_lobbyDbSubscription!.cancel());
      _lobbyDbSubscription = null;
    }
    unawaited(_dataChannel?.close());
    unawaited(_peerConnection?.dispose());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isHost && _creatorService != null) {
      _creatorService!.messageBroker.removeListener(_onBrokerUpdated);
      _creatorService!.removeListener(_onCreatorServiceUpdated);
    }
    _cleanup();
    super.dispose();
  }
}
