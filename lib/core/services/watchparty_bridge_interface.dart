import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/entity/multimedia_item.dart';

/// Decoupled WatchParty Interceptor Interface.
/// Core player and playback launcher call this interface to intercept or sync playback
/// without direct compile-time coupling to WatchParty internal package services.
abstract class WatchPartyPlaybackInterceptor {
  Future<bool> interceptPlayback(
    Ref ref,
    BuildContext context,
    String url, {
    required MultimediaItem baseItem,
    MultimediaItem? detailedItem,
  });
}

/// Decoupled WatchParty Sync Observer Interface.
/// Enables PlayerScreen to listen to sync requests and command broadcasts
/// without touching internal RTC data channel callbacks.
abstract class WatchPartySyncObserver {
  bool get isPausedForMembers;
  void registerSyncHandlers({
    required void Function(void Function(int positionMs, bool isPlaying) respond) onSyncRequested,
    required void Function(int positionMs, bool isPlaying) onSyncReceived,
    required void Function(String command, int positionMs) onCommandReceived,
  });
  void unregisterSyncHandlers();
  void unpauseForMembers();
}
