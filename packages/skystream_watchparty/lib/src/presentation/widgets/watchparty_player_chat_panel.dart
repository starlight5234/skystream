import 'package:flutter/material.dart';
import '../providers/active_watchparty_provider.dart';
import 'watchparty_chat_view.dart';

/// In-player WatchParty chat panel wrapper around [WatchPartyChatView].
class WatchPartyPlayerChatPanel extends StatelessWidget {
  final ActiveWatchPartyState? session;
  final VoidCallback? onClose;
  final void Function(String message)? onShowNotification;
  final void Function(Map<String, dynamic> mediaPayload)? onJoinMediaStream;

  const WatchPartyPlayerChatPanel({
    super.key,
    this.session,
    this.onClose,
    this.onShowNotification,
    this.onJoinMediaStream,
  });

  @override
  Widget build(BuildContext context) {
    return WatchPartyChatView(
      session: session,
      embedded: true,
      onClose: onClose,
      onShowNotification: onShowNotification,
      onJoinMediaStream: onJoinMediaStream,
    );
  }
}
