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

  final Map<String, dynamic>? activeMediaPayload;
  final bool waitForMembers;
  final bool isPausedForMembers;

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
    this.activeMediaPayload,
    this.waitForMembers = false,
    this.isPausedForMembers = false,
  });

  String? get mediaSharer =>
      activeMediaPayload?['sharer'] as String? ??
      activeMediaPayload?['sender'] as String?;

  bool get allowMemberControl =>
      activeMediaPayload?['allowMemberControl'] as bool? ?? false;

  bool get isMediaSharer {
    if (mediaSharer != null && mediaSharer!.isNotEmpty && userName.isNotEmpty) {
      return mediaSharer == userName;
    }
    return isHost;
  }

  bool get canControlPlayback =>
      isMediaSharer || allowMemberControl;

  ActiveWatchPartyState copyWith({
    Map<String, dynamic>? activeMediaPayload,
    bool clearActiveMedia = false,
    bool? waitForMembers,
    bool? isPausedForMembers,
  }) {
    return ActiveWatchPartyState(
      peerConnection: peerConnection,
      dataChannel: dataChannel,
      creatorService: creatorService,
      database: database,
      isHost: isHost,
      hostName: hostName,
      userName: userName,
      passcode: passcode,
      chatService: chatService,
      activeMediaPayload: clearActiveMedia ? null : (activeMediaPayload ?? this.activeMediaPayload),
      waitForMembers: waitForMembers ?? this.waitForMembers,
      isPausedForMembers: isPausedForMembers ?? this.isPausedForMembers,
    );
  }
}

class ActiveWatchPartyNotifier extends Notifier<ActiveWatchPartyState?> {
  @override
  ActiveWatchPartyState? build() => null;

  void setActiveSession(ActiveWatchPartyState session) {
    state = session;
  }

  void setActiveMedia(Map<String, dynamic>? mediaPayload, {bool waitForMembers = false}) {
    if (state == null) return;
    state = state!.copyWith(
      activeMediaPayload: mediaPayload,
      clearActiveMedia: mediaPayload == null,
      waitForMembers: waitForMembers,
      isPausedForMembers: waitForMembers,
    );
  }

  void unpauseForMembers() {
    if (state == null) return;
    state = state!.copyWith(
      isPausedForMembers: false,
    );
  }

  void unlockPlaybackControl() {
    if (state == null) return;
    if (state!.activeMediaPayload != null) {
      final updatedPayload = Map<String, dynamic>.from(state!.activeMediaPayload!);
      updatedPayload['allowMemberControl'] = true;
      state = state!.copyWith(activeMediaPayload: updatedPayload);
    } else {
      state = state!.copyWith(
        activeMediaPayload: {'allowMemberControl': true},
      );
    }
  }

  void clearSession() {
    state?.chatService.dispose();
    state = null;
  }
}

final activeWatchPartyProvider =
    NotifierProvider<ActiveWatchPartyNotifier, ActiveWatchPartyState?>(() {
  return ActiveWatchPartyNotifier();
});

class WatchPartyLandscapeChatNotifier extends Notifier<bool> {
  @override
  bool build() => false;

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
