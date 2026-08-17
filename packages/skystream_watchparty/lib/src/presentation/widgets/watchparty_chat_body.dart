import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../service/watchparty_chat_service.dart';
import '../../service/watchparty_creator_service.dart';
import '../providers/active_watchparty_provider.dart';

class WatchPartyChatBody extends ConsumerStatefulWidget {
  final WatchPartyChatService chatService;
  final bool isHost;
  final String passcode;
  final WatchPartyCreatorService? creatorService;
  final VoidCallback? onCopyInviteLink;
  final void Function(Map<String, dynamic> mediaPayload)? onJoinMediaStream;

  const WatchPartyChatBody({
    super.key,
    required this.chatService,
    required this.isHost,
    required this.passcode,
    this.creatorService,
    this.onCopyInviteLink,
    this.onJoinMediaStream,
  });

  @override
  ConsumerState<WatchPartyChatBody> createState() => _WatchPartyChatBodyState();
}

class _WatchPartyChatBodyState extends ConsumerState<WatchPartyChatBody> {
  final _messageController = TextEditingController();
  final _messageFocusNode = FocusNode();
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
    _messageFocusNode.dispose();
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
    _messageFocusNode.requestFocus();
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
        if (isHostWaiting)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
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
                horizontal: 16.0,
                vertical: 8.0,
              ),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final msg = messages[index];
                final isSystem = msg['type'] == 'system';
                final isMediaCard = msg['type'] == 'media_card';

                if (isMediaCard) {
                  final isMe = msg['isMe'] as bool? ?? false;
                  final sender = msg['sender'] as String? ?? (isMe ? 'You' : 'Friend');
                  final media = (msg['media'] as Map<String, dynamic>?) ?? {};
                  final title = media['title'] as String? ?? 'Shared Media';
                  final posterUrl = media['posterUrl'] as String?;
                  final providerName = media['providerName'] as String? ?? '';
                  final isTvShow = media['isTvShow'] as bool? ?? false;
                  final season = media['season'] as int?;
                  final episodeNumber = media['episodeNumber'] as int?;
                  final episodeName = media['episodeName'] as String?;

                  return Align(
                    alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      width: 260,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.movie_outlined,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '$sender shared media',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (posterUrl != null && posterUrl.isNotEmpty)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    posterUrl,
                                    width: 45,
                                    height: 65,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(Icons.movie, size: 40),
                                  ),
                                )
                              else
                                Container(
                                  width: 45,
                                  height: 65,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(Icons.movie, size: 24),
                                ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    if (isTvShow && season != null && episodeNumber != null && episodeName != 'Full Movie') ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        'S$season E$episodeNumber ${episodeName != null ? "• $episodeName" : ""}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                                      ),
                                    ],
                                    if (providerName.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        providerName,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Theme.of(context).colorScheme.outline,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Consumer(
                            builder: (context, ref, _) {
                              final activeSession = ref.watch(activeWatchPartyProvider);
                              final activeMedia = activeSession?.activeMediaPayload;
                              final bool isCurrentlyWatching;
                              if (activeMedia == null) {
                                isCurrentlyWatching = false;
                              } else {
                                final bool activeIsTv = activeMedia['isTvShow'] == true || activeMedia['episodeNumber'] != null;
                                final bool cardIsTv = media['isTvShow'] == true || media['episodeNumber'] != null;
                                if (activeIsTv || cardIsTv) {
                                  final activeTitle = activeMedia['title']?.toString().toLowerCase().trim();
                                  final cardTitle = media['title']?.toString().toLowerCase().trim();
                                  final sameShow = (activeTitle != null && activeTitle == cardTitle) ||
                                      (activeMedia['mediaUrl'] != null && activeMedia['mediaUrl'] == media['mediaUrl']);
                                  final sameSeason = activeMedia['season'] == media['season'];
                                  final sameEpisode = activeMedia['episodeNumber'] == media['episodeNumber'];
                                  isCurrentlyWatching = sameShow && sameSeason && sameEpisode;
                                } else {
                                  final activeUrl = activeMedia['mediaUrl'];
                                  final cardUrl = media['mediaUrl'];
                                  final activeTitle = activeMedia['title']?.toString().toLowerCase().trim();
                                  final cardTitle = media['title']?.toString().toLowerCase().trim();
                                  isCurrentlyWatching = (activeUrl != null && activeUrl.isNotEmpty && activeUrl == cardUrl) ||
                                      (activeTitle != null && activeTitle == cardTitle);
                                }
                              }

                              if (isCurrentlyWatching) {
                                return SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: null,
                                    icon: const Icon(Icons.check_circle_outline_rounded, size: 16),
                                    label: const Text('Currently Watching', style: TextStyle(fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                );
                              }

                              return SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: () async {
                                    if (activeMedia != null) {
                                      final switchStream = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          surfaceTintColor: Colors.transparent,
                                          title: const Text('Switch Stream?'),
                                          content: Text(
                                            'You are currently watching "${activeMedia['title'] ?? 'another video'}". Do you want to switch to "${media['title'] ?? 'this stream'}"?',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(context, false),
                                              child: const Text('Cancel'),
                                            ),
                                            ElevatedButton(
                                              onPressed: () => Navigator.pop(context, true),
                                              child: const Text('Switch'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (switchStream != true || !context.mounted) return;
                                    }
                                    widget.onJoinMediaStream?.call(media);
                                  },
                                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                                  label: const Text('Join Stream', style: TextStyle(fontSize: 12)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Theme.of(context).colorScheme.primary,
                                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                }

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

                final isMe = (msg['isMe'] as bool?) ?? false;
                final sender = msg['sender'] as String? ?? (isMe ? 'You' : 'Friend');
                final text = (msg['text'] as String?) ?? '';

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
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                text,
                                style: TextStyle(
                                  color: isMe
                                      ? Theme.of(context).colorScheme.onPrimary
                                      : Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            if (isMe && (msg['status'] == 'sending' || msg['status'] == 'pending')) ...[
                              const SizedBox(width: 4),
                              Icon(
                                Icons.schedule,
                                size: 11,
                                color: Theme.of(context).colorScheme.onPrimary.withOpacity(0.7),
                              ),
                            ] else if (isMe && msg['status'] == 'failed') ...[
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.error_outline,
                                size: 12,
                                color: Colors.orangeAccent,
                              ),
                            ],
                          ],
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
              padding: const EdgeInsets.all(16.0),
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
                          focusNode: _messageFocusNode,
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
