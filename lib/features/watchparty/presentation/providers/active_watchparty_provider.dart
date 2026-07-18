import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../data/watchparty_database.dart';
import '../../service/watchparty_creator_service.dart';
import '../../service/watchparty_chat_service.dart';
class ActiveWatchPartyState {
  final RTCPeerConnection? peerConnection;
  final RTCDataChannel? dataChannel;
  final WatchPartyCreatorService? creatorService;
  final WatchPartyDatabase database;
  final bool isHost;
  final String hostName;
  final String userName;
  final String passcode;
  final WatchPartyChatService chatService;

  const ActiveWatchPartyState({
    this.peerConnection,
    this.dataChannel,
    this.creatorService,
    required this.database,
    required this.isHost,
    required this.hostName,
    required this.userName,
    required this.passcode,
    required this.chatService,
  });
}

class ActiveWatchPartyNotifier extends Notifier<ActiveWatchPartyState?> {
  @override
  ActiveWatchPartyState? build() => null;

  void setActiveSession(ActiveWatchPartyState session) {
    state = session;
  }

  void clearSession() {
    state = null;
  }
}

final activeWatchPartyProvider =
    NotifierProvider<ActiveWatchPartyNotifier, ActiveWatchPartyState?>(() {
  return ActiveWatchPartyNotifier();
});

class WatchPartyLandscapeChatNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() {
    state = !state;
  }

  void setVisible(bool visible) {
    state = visible;
  }
}

final watchPartyLandscapeChatProvider =
    NotifierProvider<WatchPartyLandscapeChatNotifier, bool>(() {
  return WatchPartyLandscapeChatNotifier();
});
