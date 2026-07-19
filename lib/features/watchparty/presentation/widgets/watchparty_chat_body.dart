import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../settings/presentation/general_settings_provider.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../service/watchparty_chat_service.dart';
import '../../service/watchparty_creator_service.dart';

class WatchPartyChatBody extends ConsumerStatefulWidget {
  final WatchPartyChatService chatService;
  final bool isHost;
  final String passcode;
  final WatchPartyCreatorService? creatorService;
  final VoidCallback? onCopyInviteLink;

  const WatchPartyChatBody({
    super.key,
    required this.chatService,
    required this.isHost,
    required this.passcode,
    this.creatorService,
    this.onCopyInviteLink,
  });

  @override
  ConsumerState<WatchPartyChatBody> createState() => _WatchPartyChatBodyState();
}

class _WatchPartyChatBodyState extends ConsumerState<WatchPartyChatBody> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _hasGuestJoinedBefore = false;

  @override
  void initState() {
    super.initState();
    _checkGuests();
    widget.chatService.addListener(_onChatUpdate);
    widget.creatorService?.addListener(_onCreatorUpdate);
  }

  @override
  void didUpdateWidget(WatchPartyChatBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatService != widget.chatService) {
      oldWidget.chatService.removeListener(_onChatUpdate);
      widget.chatService.addListener(_onChatUpdate);
    }
    if (oldWidget.creatorService != widget.creatorService) {
      oldWidget.creatorService?.removeListener(_onCreatorUpdate);
      widget.creatorService?.addListener(_onCreatorUpdate);
    }
  }

  @override
  void dispose() {
    widget.chatService.removeListener(_onChatUpdate);
    widget.creatorService?.removeListener(_onCreatorUpdate);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onChatUpdate() {
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }
  }

  void _onCreatorUpdate() {
    if (mounted) {
      _checkGuests();
      setState(() {});
    }
  }

  void _checkGuests() {
    if (widget.isHost && widget.creatorService != null) {
      if (widget.creatorService!.activeDataChannels.isNotEmpty) {
        _hasGuestJoinedBefore = true;
      }
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    widget.chatService.sendMessage(text);
    _messageController.clear();
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.chatService.messages;
    final isHostWaiting = widget.isHost &&
        (widget.creatorService?.activeDataChannels.isEmpty ?? true) &&
        !(widget.creatorService?.hasAnyGuestJoined ?? false) &&
        !_hasGuestJoinedBefore;

    return Column(
      children: [
        if (widget.chatService.isReconnecting)
          Container(
            width: double.infinity,
            color: Colors.amber,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Reconnecting to host (Attempt ${widget.chatService.reconnectAttempts}/3)...',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (isHostWaiting)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(LayoutConstants.spacingLg),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 24),
                    Text(
                      'Waiting for guests to join...',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Lobby Passcode: ${widget.passcode}',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.onCopyInviteLink != null)
                          ElevatedButton.icon(
                            onPressed: widget.onCopyInviteLink,
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('Copy Invite Link'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          )
        else ...[
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(
                horizontal: LayoutConstants.spacingMd,
                vertical: LayoutConstants.spacingSm,
              ),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final msg = messages[index];
                final isSystem = msg['type'] == 'system';

                if (isSystem) {
                  return Align(
                    alignment: Alignment.center,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          width: 0.5,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        color: Theme.of(context).colorScheme.surfaceContainerLow,
                      ),
                      child: Text(
                        msg['text'] as String,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant
                              .withOpacity(0.8),
                        ),
                      ),
                    ),
                  );
                }

                final isMe = msg['isMe'] as bool;
                final sender = msg['sender'] as String? ?? (isMe ? 'You' : 'Friend');
                final text = msg['text'] as String;

                final reactions = ['👍', '❤️', '😂', '😮', '😢', '🎉'];
                final isEmojiReaction = reactions.contains(text.trim());

                if (isEmojiReaction) {
                  return Align(
                    alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment:
                          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
                          child: Text(
                            isMe ? 'Me' : sender,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withOpacity(0.6),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          child: Text(
                            text.trim(),
                            style: const TextStyle(fontSize: 32),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return Align(
                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment:
                        isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
                        child: Text(
                          isMe ? 'Me' : sender,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withOpacity(0.6),
                          ),
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isMe
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16).copyWith(
                            topRight: isMe ? const Radius.circular(0) : const Radius.circular(16),
                            topLeft: isMe ? const Radius.circular(16) : const Radius.circular(0),
                          ),
                        ),
                        child: Text(
                          text,
                          style: TextStyle(
                            color: isMe
                                ? Theme.of(context).colorScheme.onPrimary
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          SafeArea(
            left: false,
            right: false,
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(LayoutConstants.spacingMd),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant
                                .withValues(alpha: 0.4),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: ['👍', '❤️', '😂', '😮', '😢', '🎉'].map((emoji) {
                            return InkWell(
                              borderRadius: BorderRadius.circular(15),
                              onTap: () {
                                widget.chatService.sendMessage(emoji);
                                _scrollToBottom();
                              },
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                                child: Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 18),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          decoration: const InputDecoration(
                            hintText: 'Type a message...',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.all(Radius.circular(24)),
                            ),
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          ),
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FloatingActionButton(
                        mini: true,
                        onPressed: _sendMessage,
                        child: const Icon(Icons.send_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ]
      ],
    );
  }
}
