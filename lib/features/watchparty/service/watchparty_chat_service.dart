import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import 'watchparty_creator_service.dart';
import 'watchparty_joiner_service.dart';
import 'watchparty_crypto.dart';

class WatchPartyChatService extends ChangeNotifier {
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
  bool _connectionClosed = false;
  String? _kickMessage;
  StreamSubscription<Map<String, dynamic>?>? _lobbyDbSubscription;
  VoidCallback? onAllGuestsLeft;
  
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
    if (_isHost) {
      _setupHostListeners();
    } else {
      _setupGuestListeners();
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
              _dataChannel!.send(RTCDataChannelMessage(jsonMsg));
            } catch (_) {}
          } else if (action == 'pong') {
            _lastSeen = DateTime.now();
          } else if (action == 'leave' || action == 'kick' || action == 'host_ended') {
            _connectionClosed = true;
            _kickMessage = action == 'host_ended'
                ? 'The host has ended the watch party.'
                : (action == 'kick' ? 'You have been kicked from the lobby.' : null);
            notifyListeners();
          } else if (action == 'peer_disconnected') {
            final guest = decoded['guest'] as String? ?? 'A peer';
            _addSystemMessage('$guest has left the watch party.');
          }
          return;
        }

        _lastSeen = DateTime.now();

        if (type == 'system') {
          final systemText = decoded['text'] as String;
          _addSystemMessage(systemText);
          return;
        } else if (type == 'chat') {
          final text = decoded['text'] as String;
          final sender = decoded['sender'] as String? ?? 'Friend';
          _messages.add({
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
          'text': message.text,
          'sender': 'Friend',
          'isMe': false,
          'time': DateTime.now(),
        });
        notifyListeners();
      }
    };

    _dataChannel!.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
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
    if (_isReconnecting) return;
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
      _setupGuestListeners(); // Re-register data channel event handlers
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
        // Wait 15 seconds, then try again if still not connected and not closed
        await Future<void>.delayed(const Duration(seconds: 15));
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

      // Check timeout (no ping received from host for >30s)
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

  void sendMessage(String text) {
    if (text.isEmpty) return;

    if (_isHost) {
      if (_creatorService != null) {
        _creatorService!.messageBroker.broadcastChatMessage(_userName, text);
      }
    } else {
      if (_dataChannel != null) {
        try {
          final jsonMsg = jsonEncode({'type': 'chat', 'sender': _userName, 'text': text});
          _dataChannel!.send(RTCDataChannelMessage(jsonMsg));
        } catch (_) {
          _dataChannel!.send(RTCDataChannelMessage(text));
        }
      }
      _messages.add({
        'text': text,
        'sender': _userName,
        'isMe': true,
        'time': DateTime.now(),
      });
      notifyListeners();
    }
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
    if (_isHost && _creatorService != null) {
      _creatorService!.messageBroker.removeListener(_onBrokerUpdated);
      _creatorService!.removeListener(_onCreatorServiceUpdated);
    }
    _cleanup();
    super.dispose();
  }
}
