import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WatchPartyMessageBroker extends ChangeNotifier {
  final Map<String, RTCDataChannel> _activeDataChannels;
  final List<Map<String, dynamic>> _messages = [];
  final Map<String, DateTime> lastSeen = {};
  
  Timer? _keepAliveTimer;
  void Function(String guestName)? onGuestTimeout;
  void Function(String guestName)? onGuestLeaveRequest;

  WatchPartyMessageBroker(this._activeDataChannels) {
    _startKeepAliveTimer();
  }

  List<Map<String, dynamic>> get messages => _messages;

  void _startKeepAliveTimer() {
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 8), (timer) {
      final now = DateTime.now();

      // Send ping to all active channels
      final jsonMsg = jsonEncode({'type': 'control', 'action': 'ping'});
      for (final channel in _activeDataChannels.values) {
        try {
          channel.send(RTCDataChannelMessage(jsonMsg));
        } catch (_) {}
      }

      // Check timeouts (24 seconds)
      final deadGuests = <String>[];
      for (final entry in _activeDataChannels.entries) {
        final guest = entry.key;
        final lastTime = lastSeen[guest] ?? now;
        if (now.difference(lastTime) > const Duration(seconds: 24)) {
          deadGuests.add(guest);
        }
      }

      for (final guest in deadGuests) {
        onGuestTimeout?.call(guest);
      }
    });
  }

  void registerGuest(String guestName, RTCDataChannel channel) {
    lastSeen[guestName] = DateTime.now();
    _addSystemMessage('$guestName has joined the watch party');
    _broadcastSystemMessage('$guestName has joined the watch party');

    // Sync existing chat history to reconnected guest
    for (final msg in _messages) {
      if (msg['type'] == 'chat') {
        try {
          final syncMsg = jsonEncode({
            'type': 'chat',
            'sender': msg['sender'] ?? 'Host',
            'text': msg['text'] ?? '',
          });
          channel.send(RTCDataChannelMessage(syncMsg));
        } catch (_) {}
      }
    }

    channel.onMessage = (message) {
      _handleGuestMessage(guestName, channel, message.text);
    };
  }

  void unregisterGuest(String guestName) {
    lastSeen.remove(guestName);
    _addSystemMessage('$guestName has left the watch party');
    _broadcastSystemMessage('$guestName has left the watch party');

    final disconnectEvent = jsonEncode({
      'type': 'control',
      'action': 'peer_disconnected',
      'guest': guestName,
    });
    for (final entry in _activeDataChannels.entries) {
      if (entry.key != guestName) {
        try {
          entry.value.send(RTCDataChannelMessage(disconnectEvent));
        } catch (_) {}
      }
    }
  }

  void _handleGuestMessage(String guestName, RTCDataChannel channel, String rawText) {
    try {
      final decoded = jsonDecode(rawText) as Map<String, dynamic>;
      final type = decoded['type'] as String;
      final msgId = decoded['msgId'] as String?;

      if (msgId != null) {
        final ackMsg = jsonEncode({'type': 'control', 'action': 'msg_ack', 'msgId': msgId});
        try {
          channel.send(RTCDataChannelMessage(ackMsg));
        } catch (_) {}
      }

      if (type == 'control') {
        final action = decoded['action'] as String;
        if (action == 'ping') {
          lastSeen[guestName] = DateTime.now();
          final jsonMsg = jsonEncode({'type': 'control', 'action': 'pong'});
          try {
            channel.send(RTCDataChannelMessage(jsonMsg));
          } catch (_) {}
        } else if (action == 'pong') {
          lastSeen[guestName] = DateTime.now();
        } else if (action == 'leave') {
          onGuestLeaveRequest?.call(guestName);
        }
        return;
      }

      lastSeen[guestName] = DateTime.now();

      if (type == 'media_card') {
        _messages.add({
          'type': 'media_card',
          'sender': decoded['sender'] ?? guestName,
          'media': decoded['media'],
          'isMe': false,
          'time': DateTime.now(),
        });
        notifyListeners();
        _relayRawJson(decoded, excludeSender: guestName);
      } else if (type == 'chat') {
        final text = decoded['text'] as String;
        final sender = decoded['sender'] as String? ?? guestName;

        _messages.add({
          'type': 'chat',
          'text': text,
          'sender': sender,
          'isMe': false,
          'time': DateTime.now(),
        });
        notifyListeners();

        _relayMessage(sender, text);
      }
    } catch (_) {
      lastSeen[guestName] = DateTime.now();
      _messages.add({
        'type': 'chat',
        'text': rawText,
        'sender': guestName,
        'isMe': false,
        'time': DateTime.now(),
      });
      notifyListeners();
      _relayMessage(guestName, rawText);
    }
  }

  void broadcastMediaCard(String sender, Map<String, dynamic> mediaPayload) {
    final payload = {
      'type': 'media_card',
      'sender': sender,
      'media': mediaPayload,
    };
    final jsonMsg = jsonEncode(payload);
    for (final channel in _activeDataChannels.values) {
      try {
        channel.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}
    }
    _messages.add({
      'type': 'media_card',
      'sender': sender,
      'media': mediaPayload,
      'isMe': true,
      'time': DateTime.now(),
    });
    notifyListeners();
  }

  void broadcastRawJson(Map<String, dynamic> payload) {
    final jsonMsg = jsonEncode(payload);
    for (final channel in _activeDataChannels.values) {
      try {
        channel.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}
    }
  }

  void _relayRawJson(Map<String, dynamic> payload, {required String excludeSender}) {
    final jsonMsg = jsonEncode(payload);
    for (final entry in _activeDataChannels.entries) {
      if (entry.key != excludeSender) {
        try {
          entry.value.send(RTCDataChannelMessage(jsonMsg));
        } catch (_) {}
      }
    }
  }

  void broadcastChatMessage(String sender, String text) {
    final jsonMsg = jsonEncode({'type': 'chat', 'sender': sender, 'text': text});
    for (final channel in _activeDataChannels.values) {
      try {
        channel.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}
    }
    _messages.add({
      'text': text,
      'sender': sender,
      'isMe': true,
      'time': DateTime.now(),
    });
    notifyListeners();
  }

  void _relayMessage(String sender, String text) {
    final jsonMsg = jsonEncode({'type': 'chat', 'sender': sender, 'text': text});
    for (final entry in _activeDataChannels.entries) {
      if (entry.key != sender) {
        try {
          entry.value.send(RTCDataChannelMessage(jsonMsg));
        } catch (_) {}
      }
    }
  }

  void _broadcastSystemMessage(String text) {
    final jsonMsg = jsonEncode({'type': 'system', 'text': text});
    for (final channel in _activeDataChannels.values) {
      try {
        channel.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}
    }
  }

  void _addSystemMessage(String text) {
    _messages.add({
      'type': 'system',
      'text': text,
      'time': DateTime.now(),
    });
    notifyListeners();
  }

  void clear() {
    _messages.clear();
    lastSeen.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    super.dispose();
  }
}
