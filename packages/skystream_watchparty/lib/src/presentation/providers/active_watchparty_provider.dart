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
  final bool isLocalControlUnlocked;
  final bool forceSyncOnRejoin;

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
    this.isLocalControlUnlocked = false,
    this.forceSyncOnRejoin = false,
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
      isMediaSharer || allowMemberControl || isLocalControlUnlocked;

  bool get shouldBroadcastPlayerCommands =>
      isMediaSharer || (allowMemberControl && !isLocalControlUnlocked);

  bool get isRoomStreamActive => activeMediaPayload != null;

  static bool isSameMedia(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null || b == null) return false;
    final aEpUrl = a['episodeUrl'] as String?;
    final bEpUrl = b['episodeUrl'] as String?;
    if (aEpUrl != null && aEpUrl.isNotEmpty && bEpUrl != null && bEpUrl.isNotEmpty) {
      return aEpUrl == bEpUrl;
    }
    final aMediaUrl = a['mediaUrl'] as String?;
    final bMediaUrl = b['mediaUrl'] as String?;
    if (aMediaUrl != null && aMediaUrl.isNotEmpty && bMediaUrl != null && bMediaUrl.isNotEmpty) {
      if (aMediaUrl == bMediaUrl) return true;
    }
    final aTitle = a['title']?.toString().toLowerCase().trim();
    final bTitle = b['title']?.toString().toLowerCase().trim();
    final sameTitle = aTitle != null && aTitle == bTitle;
    final sameSeason = a['season'] == b['season'];
    final sameEpisode = a['episodeNumber'] == b['episodeNumber'];
    return sameTitle && sameSeason && sameEpisode;
  }

  ActiveWatchPartyState copyWith({
    Map<String, dynamic>? activeMediaPayload,
    bool clearActiveMedia = false,
    bool? waitForMembers,
    bool? isPausedForMembers,
    bool? isLocalControlUnlocked,
    bool? forceSyncOnRejoin,
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
      isLocalControlUnlocked: clearActiveMedia
          ? false
          : (isLocalControlUnlocked ?? this.isLocalControlUnlocked),
      forceSyncOnRejoin: forceSyncOnRejoin ?? this.forceSyncOnRejoin,
    );
  }
}

class ActiveWatchPartyNotifier extends Notifier<ActiveWatchPartyState?> {
  @override
  ActiveWatchPartyState? build() => null;

  void setActiveSession(ActiveWatchPartyState session) {
    state = session;
  }

  void setActiveMedia(
    Map<String, dynamic>? mediaPayload, {
    bool waitForMembers = false,
    bool forceSyncOnRejoin = false,
  }) {
    if (state == null) return;
    state = state!.copyWith(
      activeMediaPayload: mediaPayload,
      clearActiveMedia: mediaPayload == null,
      waitForMembers: waitForMembers,
      isPausedForMembers: waitForMembers,
      isLocalControlUnlocked: false,
      forceSyncOnRejoin: forceSyncOnRejoin,
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
    state = state!.copyWith(
      isLocalControlUnlocked: true,
    );
  }

  void resetLocalControl() {
    if (state == null) return;
    state = state!.copyWith(
      isLocalControlUnlocked: false,
    );
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
