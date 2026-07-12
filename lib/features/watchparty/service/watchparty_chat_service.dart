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
  bool _isReconnecting = false;
  int _reconnectAttempt = 0;
  static const int _maxReconnectAttempts = 3;
  String? _kickMessage;
  StreamSubscription<Map<String, dynamic>?>? _lobbyDbSubscription;
  VoidCallback? onAllGuestsLeft;

  /// Called when disconnected while the app is backgrounded / in PiP.
  /// Implement to show a system notification.
  void Function(String reason)? onDisconnectedInBackground;

  Timer? _keepAliveTimer;
  Timer? _reconnectTimer;
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
  bool get isReconnecting => _isReconnecting;
  int get reconnectAttempt => _reconnectAttempt;
  String? get kickMessage => _kickMessage;

  // ── Host side ─────────────────────────────────────────────────────────────

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

  // ── Guest side ─────────────────────────────────────────────────────────────

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
            try {
              _dataChannel!.send(RTCDataChannelMessage(
                jsonEncode({'type': 'control', 'action': 'pong'}),
              ));
            } catch (_) {}
          } else if (action == 'pong') {
            _lastSeen = DateTime.now();
            // A pong means we're still connected; cancel any reconnect attempt.
            if (_isReconnecting) {
              _reconnectTimer?.cancel();
              _reconnectTimer = null;
              _isReconnecting = false;
              _reconnectAttempt = 0;
              notifyListeners();
            }
          } else if (action == 'leave') {
            _handleExplicitDisconnect(null);
          } else if (action == 'kick') {
            _handleExplicitDisconnect('You have been kicked from the lobby.');
          } else if (action == 'host_ended') {
            _handleExplicitDisconnect('The host has ended the WatchParty.');
          }
          return;
        }

        _lastSeen = DateTime.now();

        if (type == 'system') {
          _addSystemMessage(decoded['text'] as String);
        } else if (type == 'chat') {
          _messages.add({
            'text': decoded['text'] as String,
            'sender': decoded['sender'] as String? ?? 'Friend',
            'isMe': false,
            'time': DateTime.now(),
          });
          notifyListeners();
        } else if (type == 'reaction') {
          _messages.add({
            'type': 'reaction',
            'emoji': decoded['emoji'] as String,
            'sender': decoded['sender'] as String? ?? 'Friend',
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
        // Don't mark as closed yet — let the keep-alive timer try to reconnect.
        if (!_connectionClosed) {
          _startReconnect('Data channel closed unexpectedly.');
        }
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

      try {
        _dataChannel!.send(RTCDataChannelMessage(
          jsonEncode({'type': 'control', 'action': 'ping'}),
        ));
      } catch (_) {}

      if (DateTime.now().difference(_lastSeen) > const Duration(seconds: 30)) {
        timer.cancel();
        _startReconnect('Host did not respond to keep-alive pings.');
      }
    });
  }

  /// Begins the reconnect countdown (up to 3 attempts, 5s apart).
  /// Only used for timeout/channel-close scenarios — explicit kicks/host_ended
  /// do NOT retry and go straight to _handleExplicitDisconnect().
  void _startReconnect(String reason) {
    if (_isReconnecting || _connectionClosed) return;
    _isReconnecting = true;
    _reconnectAttempt = 0;
    notifyListeners();
    _scheduleNextReconnect(reason);
  }

  void _scheduleNextReconnect(String reason) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (_connectionClosed) return;
      _reconnectAttempt++;
      if (_reconnectAttempt > _maxReconnectAttempts) {
        // All attempts exhausted — declare session lost.
        _isReconnecting = false;
        _kickMessage = 'Connection lost after $_maxReconnectAttempts reconnect attempts.';
        _notifyDisconnected(_kickMessage!);
        return;
      }

      // Send a ping and wait for a pong (handled in the message handler above).
      try {
        _dataChannel?.send(RTCDataChannelMessage(
          jsonEncode({'type': 'control', 'action': 'ping'}),
        ));
      } catch (_) {}
      notifyListeners();
      // Schedule next attempt; if pong arrives first, this timer is cancelled.
      _scheduleNextReconnect(reason);
    });
  }

  /// Called for intentional explicit events (host_ended, kick, leave) — no retry.
  void _handleExplicitDisconnect(String? reason) {
    if (reason != null) {
      _addSystemMessage(reason);
    }
    _kickMessage = reason;
    _notifyDisconnected(reason ?? 'The host disconnected from the watch party.');
  }

  void _notifyDisconnected(String reason) {
    _connectionClosed = true;
    _cleanup();
    notifyListeners();
    // If the app is in the background, fire the background-notification callback.
    onDisconnectedInBackground?.call(reason);
  }

  void _setupDbListener() {
    _lobbyDbSubscription = _database
        .subscribeToLobby(hostName: _hostName)
        .listen((row) {
      if (row == null && !_connectionClosed) {
        // Lobby row deleted — start reconnect before declaring lost.
        _startReconnect('Lobby row removed from database.');
      }
    });
  }

  void _addSystemMessage(String text) {
    _messages.add({'type': 'system', 'text': text, 'time': DateTime.now()});
    notifyListeners();
  }

  // ── Sending ────────────────────────────────────────────────────────────────

  void sendMessage(String text) {
    if (text.isEmpty) return;

    if (_isHost) {
      _creatorService?.messageBroker.broadcastChatMessage(_userName, text);
    } else {
      if (_dataChannel != null) {
        try {
          _dataChannel!.send(RTCDataChannelMessage(
            jsonEncode({'type': 'chat', 'sender': _userName, 'text': text}),
          ));
        } catch (_) {}
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

  void sendReaction(String emoji) {
    if (_isHost) {
      _creatorService?.messageBroker.broadcastReaction(_userName, emoji);
    } else {
      if (_dataChannel != null) {
        try {
          _dataChannel!.send(RTCDataChannelMessage(
            jsonEncode({'type': 'reaction', 'sender': _userName, 'emoji': emoji}),
          ));
        } catch (_) {}
      }
      _messages.add({
        'type': 'reaction',
        'emoji': emoji,
        'sender': _userName,
        'isMe': true,
        'time': DateTime.now(),
      });
      notifyListeners();
    }
  }

  // ── Leave / Cleanup ────────────────────────────────────────────────────────

  Future<void> leaveParty() async {
    if (_isHost) {
      // Explicitly notify all guests before tearing down.
      _creatorService?.messageBroker.broadcastHostEnded();
      await Future<void>.delayed(const Duration(milliseconds: 100)); // flush buffer
      await _creatorService?.cancelHosting();
    } else {
      if (_dataChannel != null) {
        try {
          _dataChannel!.send(RTCDataChannelMessage(
            jsonEncode({'type': 'control', 'action': 'leave'}),
          ));
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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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
