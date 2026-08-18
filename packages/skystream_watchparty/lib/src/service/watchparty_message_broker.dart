import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WatchPartyMessageBroker extends ChangeNotifier {
  final Map<String, RTCDataChannel> _activeDataChannels;
  final List<Map<String, dynamic>> _messages = [];
  final Map<String, DateTime> lastSeen = {};
  final Map<String, Set<String>> _mediaVotes = {};
  String? activeMediaSharer;
  
  Timer? _keepAliveTimer;
  void Function(String guestName)? onGuestTimeout;
  void Function(String guestName)? onGuestLeaveRequest;
  void Function(String requesterName)? onSyncStateRequested;
  void Function(int positionMs, bool isPlaying)? onSyncStateReceived;
  void Function(String cmd, int positionMs)? onPlayerCommandReceived;
  void Function(String sharerName)? onSharerLeftStream;

  WatchPartyMessageBroker(this._activeDataChannels) {
    _startKeepAliveTimer();
  }

  List<Map<String, dynamic>> get messages => _messages;
  Map<String, Set<String>> get mediaVotes => _mediaVotes;

  int getMediaVoteCount(String mediaKey) => _mediaVotes[mediaKey]?.length ?? 0;
  bool hasUserVoted(String mediaKey, String userName) =>
      _mediaVotes[mediaKey]?.contains(userName) ?? false;

  void toggleMediaVote(String mediaKey, String voter) {
    final currentSet = _mediaVotes.putIfAbsent(mediaKey, () => <String>{});
    final bool voted;
    if (currentSet.contains(voter)) {
      currentSet.remove(voter);
      voted = false;
    } else {
      currentSet.add(voter);
      voted = true;
    }
    final jsonMsg = jsonEncode({
      'type': 'control',
      'action': 'vote_media',
      'mediaKey': mediaKey,
      'voter': voter,
      'voted': voted,
    });
    for (final ch in _activeDataChannels.values) {
      try {
        ch.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}
    }
    notifyListeners();
  }

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

      // Check timeouts (45 seconds to accommodate temporary phone sleep/lock)
      final deadGuests = <String>[];
      for (final entry in _activeDataChannels.entries) {
        final guest = entry.key;
        final lastTime = lastSeen[guest] ?? now;
        if (now.difference(lastTime) > const Duration(seconds: 45)) {
          deadGuests.add(guest);
        }
      }

      for (final guest in deadGuests) {
        onGuestTimeout?.call(guest);
      }
    });
  }

  void registerGuest(String guestName, RTCDataChannel channel) {
    final isRejoining = lastSeen.containsKey(guestName);
    lastSeen[guestName] = DateTime.now();

    if (!isRejoining) {
      _addSystemMessage('$guestName has joined the watch party');
      _broadcastSystemMessage('$guestName has joined the watch party');
    }

    // Sync existing media votes snapshot to new guest
    if (_mediaVotes.isNotEmpty) {
      final serializedVotes = _mediaVotes.map((k, v) => MapEntry(k, v.toList()));
      final syncVotesMsg = jsonEncode({
        'type': 'control',
        'action': 'sync_votes',
        'votes': serializedVotes,
      });
      try {
        channel.send(RTCDataChannelMessage(syncVotesMsg));
      } catch (_) {}
    }

    // Sync full existing chat history (chat, media cards) to newly joined guest only (not rejoining/reconnecting)
    // Use batching with small yields to prevent saturating the WebRTC send buffer
    if (_messages.isNotEmpty && !isRejoining) {
      final historySnapshot = List<Map<String, dynamic>>.from(_messages);
      unawaited(Future(() async {
        const batchSize = 15;
        for (int i = 0; i < historySnapshot.length; i += batchSize) {
          if (channel.state != RTCDataChannelState.RTCDataChannelOpen) break;
          final end = (i + batchSize < historySnapshot.length) ? i + batchSize : historySnapshot.length;
          final batch = historySnapshot.sublist(i, end);
          for (final msg in batch) {
            try {
              final type = msg['type'] as String?;
              if (type == 'chat') {
                final syncMsg = jsonEncode({
                  'type': 'chat',
                  'msgId': msg['msgId'],
                  'sender': msg['sender'] ?? 'Host',
                  'text': msg['text'] ?? '',
                });
                channel.send(RTCDataChannelMessage(syncMsg));
              } else if (type == 'media_card') {
                final syncMsg = jsonEncode({
                  'type': 'media_card',
                  'msgId': msg['msgId'],
                  'sender': msg['sender'] ?? 'Host',
                  'media': msg['media'],
                });
                channel.send(RTCDataChannelMessage(syncMsg));
              }
            } catch (_) {}
          }
          if (end < historySnapshot.length) {
            await Future<void>.delayed(const Duration(milliseconds: 15));
          }
        }
      }));
    }

    channel.onMessage = (message) {
      _handleGuestMessage(guestName, channel, message.text);
    };
  }

  void unregisterGuest(String guestName) {
    lastSeen.remove(guestName);
    _addSystemMessage('$guestName has left the watch party');
    _broadcastSystemMessage('$guestName has left the watch party');

    if (activeMediaSharer != null && activeMediaSharer == guestName) {
      activeMediaSharer = null;
      onSharerLeftStream?.call(guestName);
      final sharerLeftEvent = jsonEncode({
        'type': 'control',
        'action': 'sharer_left_stream',
        'sharer': guestName,
      });
      for (final entry in _activeDataChannels.entries) {
        if (entry.key != guestName) {
          try {
            entry.value.send(RTCDataChannelMessage(sharerLeftEvent));
          } catch (_) {}
        }
      }
    }

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
          DateTime.now().difference((m['time'] as DateTime? ?? DateTime.now())).inSeconds < 5);
      if (exists) return;
    }

    _messages.add(item);
    notifyListeners();
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
        } else if (action == 'get_sync_state') {
          final requester = decoded['requester'] as String? ?? guestName;
          onSyncStateRequested?.call(requester);
          _relayRawJson(decoded, excludeChannelKey: guestName);
        } else if (action == 'sync_state_response') {
          final positionMs = decoded['positionMs'] as int? ?? 0;
          final isPlaying = decoded['isPlaying'] as bool? ?? false;
          onSyncStateReceived?.call(positionMs, isPlaying);
          _relayRawJson(decoded, excludeChannelKey: guestName);
        } else if (action == 'player_command') {
          if (activeMediaSharer != null && activeMediaSharer != guestName) {
            return;
          }
          final cmd = decoded['cmd'] as String? ?? 'ping';
          final positionMs = decoded['positionMs'] as int? ?? 0;
          onPlayerCommandReceived?.call(cmd, positionMs);
          _relayRawJson(decoded, excludeChannelKey: guestName);
        } else if (action == 'vote_media') {
          final mediaKey = decoded['mediaKey'] as String?;
          final voter = decoded['voter'] as String? ?? guestName;
          final voted = decoded['voted'] as bool? ?? true;
          if (mediaKey != null && mediaKey.isNotEmpty) {
            final currentSet = _mediaVotes.putIfAbsent(mediaKey, () => <String>{});
            if (voted) {
              currentSet.add(voter);
            } else {
              currentSet.remove(voter);
            }
            notifyListeners();
            _relayRawJson(decoded, excludeChannelKey: guestName);
          }
        } else if (action == 'sharer_left_stream') {
          final sharer = decoded['sharer'] as String? ?? guestName;
          if (activeMediaSharer == sharer) {
            activeMediaSharer = null;
          }
          onSharerLeftStream?.call(sharer);
          _relayRawJson(decoded, excludeChannelKey: guestName);
        }
        return;
      }

      lastSeen[guestName] = DateTime.now();

      if (type == 'media_card') {
        final sender = decoded['sender'] as String? ?? guestName;
        activeMediaSharer = sender;
        _addDeduplicatedMessage({
          'type': 'media_card',
          'msgId': msgId,
          'sender': sender,
          'media': decoded['media'],
          'isMe': false,
          'time': DateTime.now(),
        });
        _relayRawJson(decoded, excludeChannelKey: guestName);
      } else if (type == 'chat') {
        final text = decoded['text'] as String;
        final sender = decoded['sender'] as String? ?? guestName;

        _addDeduplicatedMessage({
          'type': 'chat',
          'msgId': msgId,
          'text': text,
          'sender': sender,
          'isMe': false,
          'time': DateTime.now(),
        });

        _relayMessage(sender, text, msgId: msgId, excludeChannelKey: guestName);
      }
    } catch (_) {
      if (rawText.trim().startsWith('{')) return;
      lastSeen[guestName] = DateTime.now();
      _addDeduplicatedMessage({
        'type': 'chat',
        'text': rawText,
        'sender': guestName,
        'isMe': false,
        'time': DateTime.now(),
      });
      _relayMessage(guestName, rawText, excludeChannelKey: guestName);
    }
  }

  void broadcastMediaCard(String sender, Map<String, dynamic> mediaPayload, {String? msgId}) {
    activeMediaSharer = sender;
    final effectiveMsgId = msgId ?? '${DateTime.now().millisecondsSinceEpoch}_${_messages.length}';
    final payload = {
      'type': 'media_card',
      'msgId': effectiveMsgId,
      'sender': sender,
      'media': mediaPayload,
    };
    final jsonMsg = jsonEncode(payload);
    for (final channel in _activeDataChannels.values) {
      try {
        channel.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}
    }
    _addDeduplicatedMessage({
      'type': 'media_card',
      'msgId': effectiveMsgId,
      'sender': sender,
      'media': mediaPayload,
      'isMe': true,
      'time': DateTime.now(),
    });
  }

  void broadcastRawJson(Map<String, dynamic> payload) {
    final jsonMsg = jsonEncode(payload);
    for (final channel in _activeDataChannels.values) {
      try {
        channel.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}
    }
  }

  void _relayRawJson(Map<String, dynamic> payload, {required String excludeChannelKey}) {
    final jsonMsg = jsonEncode(payload);
    for (final entry in _activeDataChannels.entries) {
      if (entry.key != excludeChannelKey) {
        try {
          entry.value.send(RTCDataChannelMessage(jsonMsg));
        } catch (_) {}
      }
    }
  }

  void broadcastChatMessage(String sender, String text, {String? msgId}) {
    final effectiveMsgId = msgId ?? '${DateTime.now().millisecondsSinceEpoch}_${_messages.length}';
    final jsonMsg = jsonEncode({'type': 'chat', 'msgId': effectiveMsgId, 'sender': sender, 'text': text});
    for (final channel in _activeDataChannels.values) {
      try {
        channel.send(RTCDataChannelMessage(jsonMsg));
      } catch (_) {}
    }
    _addDeduplicatedMessage({
      'type': 'chat',
      'msgId': effectiveMsgId,
      'text': text,
      'sender': sender,
      'isMe': true,
      'time': DateTime.now(),
    });
  }

  void _relayMessage(String sender, String text, {String? msgId, String? excludeChannelKey}) {
    final jsonMsg = jsonEncode({'type': 'chat', 'msgId': msgId, 'sender': sender, 'text': text});
    for (final entry in _activeDataChannels.entries) {
      if (entry.key != excludeChannelKey) {
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
    _mediaVotes.clear();
    activeMediaSharer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    super.dispose();
  }
}
