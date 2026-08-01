import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// WhatsApp-grade Outbox Manager.
/// Manages message delivery states (sending -> sent -> delivered), ACK tracking,
/// and automatic retry flushing when DataChannel opens.
class WatchPartyOutboxManager {
  final Map<String, Map<String, dynamic>> _pendingOutbox = {};
  final Map<String, Timer> _ackTimers = {};

  /// Adds a message to the pending outbox queue and schedules ACK timeout (5 seconds).
  void enqueue(Map<String, dynamic> message, {required void Function(String msgId) onAckTimeout}) {
    final msgId = message['msgId'] as String?;
    if (msgId == null || msgId.isEmpty) return;

    _pendingOutbox[msgId] = Map<String, dynamic>.from(message);

    // Schedule 5-second ACK timeout
    _ackTimers[msgId]?.cancel();
    _ackTimers[msgId] = Timer(const Duration(seconds: 5), () {
      _ackTimers.remove(msgId);
      if (_pendingOutbox.containsKey(msgId)) {
        _pendingOutbox[msgId]!['status'] = 'failed';
        onAckTimeout(msgId);
      }
    });
  }

  /// Processes incoming ACK for a message.
  bool acknowledge(String msgId) {
    _ackTimers[msgId]?.cancel();
    _ackTimers.remove(msgId);

    final item = _pendingOutbox.remove(msgId);
    if (item != null) {
      item['status'] = 'delivered';
      return true;
    }
    return false;
  }

  /// Flushes all pending outbox messages over active DataChannel sequentially.
  void flush(RTCDataChannel channel) {
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) return;
    if (_pendingOutbox.isEmpty) return;

    final items = List<Map<String, dynamic>>.from(_pendingOutbox.values);
    for (final item in items) {
      try {
        final msgId = item['msgId'] as String?;
        final type = item['type'] as String? ?? 'chat';

        if (type == 'media_card') {
          final payload = {
            'type': 'media_card',
            'msgId': msgId,
            'sender': item['sender'],
            'media': item['media'],
          };
          channel.send(RTCDataChannelMessage(jsonEncode(payload)));
        } else {
          final payload = {
            'type': 'chat',
            'msgId': msgId,
            'sender': item['sender'],
            'text': item['text'],
          };
          channel.send(RTCDataChannelMessage(jsonEncode(payload)));
        }
        item['status'] = 'sent';
      } catch (_) {
        break;
      }
    }
  }

  /// Returns un-acknowledged pending messages.
  List<Map<String, dynamic>> get pendingMessages => List.unmodifiable(_pendingOutbox.values);

  void dispose() {
    for (final timer in _ackTimers.values) {
      timer.cancel();
    }
    _ackTimers.clear();
    _pendingOutbox.clear();
  }
}
