import 'package:flutter/material.dart';
import 'providers/active_watchparty_provider.dart';
import 'widgets/watchparty_chat_view.dart';

/// Full-screen WatchParty chat screen wrapper around [WatchPartyChatView].
class WatchPartyChatScreen extends StatelessWidget {
  final ActiveWatchPartyState session;
  final void Function(Map<String, dynamic> mediaPayload)? onJoinMediaStream;

  const WatchPartyChatScreen({
    super.key,
    required this.session,
    this.onJoinMediaStream,
  });

  @override
  Widget build(BuildContext context) {
    return WatchPartyChatView(
      session: session,
      embedded: false,
      onJoinMediaStream: onJoinMediaStream,
    );
  }
}
