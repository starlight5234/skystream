import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import 'watchparty_creator_service.dart';
import 'watchparty_crypto.dart';

class WatchPartyChatService extends ChangeNotifier {
  final RTCPeerConnection? _peerConnection;
  final RTCDataChannel? _dataChannel;
  final WatchPartyCreatorService? _creatorService;
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
    required WatchPartyDatabase database,
    required bool isHost,
    required String hostName,
    required String userName,
    required String passcode,
  })  : _peerConnection = peerConnection,
        _dataChannel = dataChannel,
        _creatorService = creatorService,
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

  void _setupHostListeners() {
    if (_creatorService == null) return;

    _creatorService!.messageBroker.addListener(_onBrokerUpdated);

    _creatorService!.onGuestDisconnected = (guestName) {
      if (_creatorService!.activeDataChannels.isEmpty) {
        onAllGuestsLeft?.call();
      }
    };
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
          } else if (action == 'leave' || action == 'kick') {
            _connectionClosed = true;
            _kickMessage = action == 'kick' ? 'You have been kicked from the lobby.' : null;
            notifyListeners();
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
        _connectionClosed = true;
        notifyListeners();
      }
    };

    _setupDbListener();
  }

  void _startGuestKeepAliveTimer() {
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (_connectionClosed || _dataChannel == null) {
        timer.cancel();
        return;
      }

      // Send ping to host
      final jsonMsg = jsonEncode({'type': 'control', 'action': 'ping'});
      try {
        _dataChannel!.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}

      // Check timeout
      if (DateTime.now().difference(_lastSeen) > const Duration(seconds: 30)) {
        _connectionClosed = true;
        _kickMessage = 'Connection lost: Host did not respond to keep-alive pings.';
        notifyListeners();
        timer.cancel();
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
    }
    _cleanup();
    super.dispose();
  }
}
