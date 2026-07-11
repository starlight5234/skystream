import 'package:flutter_riverpod/flutter_riverpod.dart';

class WatchPartyNotificationState {
  final bool hasUnread;
  final int messageCount;

  const WatchPartyNotificationState({
    this.hasUnread = false,
    this.messageCount = 0,
  });

  WatchPartyNotificationState copyWith({
    bool? hasUnread,
    int? messageCount,
  }) {
    return WatchPartyNotificationState(
      hasUnread: hasUnread ?? this.hasUnread,
      messageCount: messageCount ?? this.messageCount,
    );
  }
}

class WatchPartyNotificationNotifier extends Notifier<WatchPartyNotificationState> {
  @override
  WatchPartyNotificationState build() => const WatchPartyNotificationState();

  void addNotification() {
    state = state.copyWith(
      hasUnread: true,
      messageCount: state.messageCount + 1,
    );
  }

  void clearNotifications() {
    state = const WatchPartyNotificationState();
  }
}

/// Tracks the unread message notification badge state.
final watchPartyNotificationProvider =
    NotifierProvider<WatchPartyNotificationNotifier, WatchPartyNotificationState>(() {
  return WatchPartyNotificationNotifier();
});

class WatchPartyActiveTabNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setActive(bool active) {
    state = active;
  }
}

/// Tracks if the user is actively viewing the Watch Party screen tab.
final watchPartyActiveTabProvider =
    NotifierProvider<WatchPartyActiveTabNotifier, bool>(() {
  return WatchPartyActiveTabNotifier();
});
