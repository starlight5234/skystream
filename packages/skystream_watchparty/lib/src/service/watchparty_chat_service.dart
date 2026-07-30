import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import 'watchparty_creator_service.dart';
import 'watchparty_joiner_service.dart';

class WatchPartyChatService extends ChangeNotifier with WidgetsBindingObserver {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  final WatchPartyCreatorService? _creatorService;
  final WatchPartyJoinerService? _joinerService;
  final WatchPartyDatabase _database;
  final bool _isHost;
  final String _hostName;
  final String _userName;
  final String _passcode;

  final List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _outboxQueue = [];
  bool _connectionClosed = false;
  String? _kickMessage;
  StreamSubscription<Map<String, dynamic>?>? _lobbyDbSubscription;
  VoidCallback? onAllGuestsLeft;
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onAppResumed();
    }
  }

  void _onAppResumed() {
    if (_isHost || _connectionClosed) return;
    final isChannelOpen = _dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen;
    if (!isChannelOpen && !_isReconnecting) {
      _attemptReconnection();
    } else if (isChannelOpen) {
      _flushOutbox();
    }
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
          if (mediaPayload != null) {
            _messages.add({
              'type': 'media_card',
              'sender': sender,
              'media': mediaPayload,
              'isMe': false,
              'time': DateTime.now(),
            });
            notifyListeners();
          }
        } else if (type == 'chat') {
          _lastSeen = DateTime.now();
          final text = decoded['text'] as String;
          final sender = decoded['sender'] as String? ?? 'Friend';
          _messages.add({
            'type': 'chat',
            'text': text,
            'sender': sender,
            'isMe': false,
            'time': DateTime.now(),
          });
          notifyListeners();
        }
      } catch (_) {
        _lastSeen = DateTime.now();
        _messages.add({
          'type': 'chat',
          'text': message.text,
          'sender': 'Friend',
          'isMe': false,
          'time': DateTime.now(),
        });
        notifyListeners();
      }
    };

    _dataChannel!.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _flushOutbox();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        if (!_connectionClosed && !_isReconnecting) {
          _attemptReconnection();
        } else if (_connectionClosed) {
          notifyListeners();
        }
      }
    };

    _setupDbListener();
  }

  int _reconnectAttempts = 0;
  bool _isReconnecting = false;

  Future<void> _attemptReconnection() async {
    if (_isReconnecting || _connectionClosed) return;

    // Check if host deleted the lobby before attempting reconnection
    try {
      final lobby = await _database.getLobby(hostName: _hostName);
      if (lobby == null) {
        _connectionClosed = true;
        _isReconnecting = false;
        _kickMessage = 'The host has ended the watch party.';
        notifyListeners();
        return;
      }
    } catch (_) {}

    _isReconnecting = true;
    _reconnectAttempts++;
    notifyListeners();
    
    final joiner = _joinerService;
    if (joiner == null) {
      _connectionClosed = true;
      _kickMessage = 'Reconnection failed: Joiner service is unavailable.';
      _isReconnecting = false;
      notifyListeners();
      return;
    }

    final success = await joiner.reconnect();
    if (success) {
      _peerConnection = joiner.peerConnection;
      _dataChannel = joiner.dataChannel;
      _isReconnecting = false;
      _reconnectAttempts = 0;
      _lastSeen = DateTime.now();
      _setupGuestListeners();
      _flushOutbox();
      _addSystemMessage('Reconnected to host.');
      notifyListeners();
    } else {
      _isReconnecting = false;
      if (_reconnectAttempts >= 3) {
        _connectionClosed = true;
        _kickMessage = 'Connection lost after 3 reconnection attempts.';
        notifyListeners();
      } else {
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 10));
        if (!_connectionClosed && !_isReconnecting && _reconnectAttempts < 3) {
          _attemptReconnection();
        }
      }
    }
  }

  void _startGuestKeepAliveTimer() {
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (_connectionClosed || _dataChannel == null) {
        timer.cancel();
        return;
      }

      if (DateTime.now().difference(_lastSeen) > const Duration(seconds: 30)) {
        timer.cancel();
        _attemptReconnection();
      }
    });
  }

  void _setupDbListener() {
    _lobbyDbSubscription = _database.subscribeToLobby(hostName: _hostName).listen((row) {
      if (row == null) {
        _connectionClosed = true;
        _isReconnecting = false;
        _kickMessage = 'The host has ended the watch party.';
        notifyListeners();
      }
    });
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

    final toRemove = <Map<String, dynamic>>[];
    for (final item in _outboxQueue) {
      try {
        final text = item['text'] as String;
        final jsonMsg = jsonEncode({'type': 'chat', 'sender': _userName, 'text': text});
        _dataChannel!.send(RTCDataChannelMessage(jsonMsg));
        item['status'] = 'sent';
        toRemove.add(item);
      } catch (_) {
        break;
      }
    }
    _outboxQueue.removeWhere(toRemove.contains);
    notifyListeners();
  }

  void sendMediaCard(Map<String, dynamic> mediaPayload) {
    final messageItem = {
      'type': 'media_card',
      'sender': _userName,
      'media': mediaPayload,
      'isMe': true,
      'time': DateTime.now(),
      'status': 'sending',
    };

    if (_isHost) {
      if (_creatorService != null) {
        _creatorService!.messageBroker.broadcastMediaCard(_userName, mediaPayload);
        messageItem['status'] = 'sent';
      }
      notifyListeners();
      return;
    }

    final isChannelOpen = _dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen &&
        !_isReconnecting;

    if (isChannelOpen) {
      try {
        final jsonMsg = jsonEncode({
          'type': 'media_card',
          'sender': _userName,
          'media': mediaPayload,
        });
        _dataChannel!.send(RTCDataChannelMessage(jsonMsg));
        messageItem['status'] = 'sent';
      } catch (_) {
        messageItem['status'] = 'pending';
      }
    }

    _messages.add(messageItem);
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

    final messageItem = {
      'type': 'chat',
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

    final isChannelOpen = _dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen &&
        !_isReconnecting;

    if (isChannelOpen) {
      try {
        final jsonMsg = jsonEncode({'type': 'chat', 'sender': _userName, 'text': trimmed});
        _dataChannel!.send(RTCDataChannelMessage(jsonMsg));
        messageItem['status'] = 'sent';
      } catch (_) {
        messageItem['status'] = 'pending';
        _outboxQueue.add(messageItem);
        _attemptReconnection();
      }
    } else {
      messageItem['status'] = 'pending';
      _outboxQueue.add(messageItem);
      _attemptReconnection();
    }

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
    _connectionClosed = true;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
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
