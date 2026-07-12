import 'package:flutter_riverpod/flutter_riverpod.dart';

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
