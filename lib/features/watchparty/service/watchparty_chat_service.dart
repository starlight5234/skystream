import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import 'watchparty_crypto.dart';

class WatchPartyChatService extends ChangeNotifier {
  final RTCPeerConnection _peerConnection;
  final RTCDataChannel _dataChannel;
  final WatchPartyDatabase _database;
  final bool _isHost;
  final String _hostName;
  final String _userName;
  final String _passcode;

  final List<Map<String, dynamic>> _messages = [];
  bool _connectionClosed = false;
  StreamSubscription<Map<String, dynamic>?>? _lobbyDbSubscription;

  WatchPartyChatService({
    required RTCPeerConnection peerConnection,
    required RTCDataChannel dataChannel,
    required WatchPartyDatabase database,
    required bool isHost,
    required String hostName,
    required String userName,
    required String passcode,
  })  : _peerConnection = peerConnection,
        _dataChannel = dataChannel,
        _database = database,
        _isHost = isHost,
        _hostName = hostName,
        _userName = userName,
        _passcode = passcode {
    _setupListeners();
    _setupDbListener();
  }

  List<Map<String, dynamic>> get messages => _messages;
  bool get connectionClosed => _connectionClosed;

  void _setupListeners() {
    _dataChannel.onMessage = (message) {
      try {
        final decoded = jsonDecode(message.text) as Map<String, dynamic>;
        final type = decoded['type'] as String;
        if (type == 'control') {
          final action = decoded['action'] as String;
          if (action == 'leave') {
            _connectionClosed = true;
            notifyListeners();
          }
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
        // Fallback for plain text if any unformatted message is received
        _messages.add({
          'text': message.text,
          'isMe': false,
          'time': DateTime.now(),
        });
        notifyListeners();
      }
    };

    _dataChannel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _connectionClosed = true;
        notifyListeners();
      }
    };
  }

  void _setupDbListener() {
    _lobbyDbSubscription = _database.subscribeToLobby(hostName: _hostName).listen((row) {
      if (row == null) {
        _connectionClosed = true;
        notifyListeners();
      }
    });
  }

  void sendMessage(String text) {
    if (text.isEmpty) return;
    try {
      final jsonMsg = jsonEncode({'type': 'chat', 'sender': _userName, 'text': text});
      _dataChannel.send(RTCDataChannelMessage(jsonMsg));
    } catch (_) {
      _dataChannel.send(RTCDataChannelMessage(text));
    }
    _messages.add({
      'text': text,
      'sender': _userName,
      'isMe': true,
      'time': DateTime.now(),
    });
    notifyListeners();
  }

  Future<void> leaveParty() async {
    try {
      final jsonMsg = jsonEncode({'type': 'control', 'action': 'leave'});
      _dataChannel.send(RTCDataChannelMessage(jsonMsg));
    } catch (_) {}
    if (_isHost) {
      try {
        final hash = WatchPartyCrypto.hashPasscode(_passcode, _hostName);
        await _database.deleteLobby(hostName: _hostName, passcodeHash: hash);
      } catch (_) {}
    } else {
      try {
        await _database.leaveLobby(hostName: _hostName, guestName: _userName);
      } catch (_) {}
    }
    _cleanup();
  }

  void _cleanup() {
    if (_lobbyDbSubscription != null) {
      unawaited(_lobbyDbSubscription!.cancel());
      _lobbyDbSubscription = null;
    }
    unawaited(_dataChannel.close());
    unawaited(_peerConnection.dispose());
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}
