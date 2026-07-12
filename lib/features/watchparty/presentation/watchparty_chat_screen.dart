import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../core/utils/layout_constants.dart';
import '../../settings/presentation/general_settings_provider.dart';
import '../config/watchparty_config.dart';
import '../service/watchparty_crypto.dart';
import 'providers/active_watchparty_provider.dart';
import '../../player/presentation/in_app_player_provider.dart';

// Quick reactions available in the bar above the input.
const _kReactions = ['👍', '❤️', '😂', '😮', '😢', '👏'];

/// Fully provider-driven chat screen.
/// Has no constructor params — reads everything from [activeWatchPartyProvider].
/// Can be embedded inline inside WatchPartyScreen (tab root) or used as a
/// standalone pushed route for the player auxiliary panel.
class WatchPartyChatScreen extends ConsumerStatefulWidget {
  /// When [isInline] is true the screen is embedded as the WatchParty tab root
  /// and navigating "back" is handled by the shell router (no pop needed).
  final bool isInline;
  const WatchPartyChatScreen({super.key, this.isInline = false});

  @override
  ConsumerState<WatchPartyChatScreen> createState() =>
      _WatchPartyChatScreenState();
}

class _WatchPartyChatScreenState extends ConsumerState<WatchPartyChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _messageFocusNode = FocusNode();
  bool _disconnectDialogShowing = false;
  bool _hasGuestJoinedBefore = false;

  // Connection quality indicator.
  Timer? _pingTimer;
  DateTime _lastPong = DateTime.now();
  Color _connectionColor = Colors.green;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = ref.read(activeWatchPartyProvider);
      if (session != null) {
        session.chatService.addListener(_onChatServiceChanged);
        if (session.isHost) {
          session.creatorService?.addListener(_onCreatorServiceChanged);
          session.chatService.onAllGuestsLeft = () {
            if (!mounted) return;
            showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                surfaceTintColor: Colors.transparent,
                title: const Text('WatchParty Update'),
                content:
                    const Text('All guests have left the watch party lobby.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          };
        }
      }
    });

    // Start the connection quality timer.
    _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      final age = DateTime.now().difference(_lastPong).inSeconds;
      setState(() {
        _connectionColor = age < 5
            ? Colors.green
            : age < 15
                ? Colors.amber
                : Colors.red;
      });
    });
  }

  void _onChatServiceChanged() {
    if (!mounted) return;
    setState(() {});
    
    final session = ref.read(activeWatchPartyProvider);
    if (session == null) return;
    
    _scrollToBottom();

    if (session.chatService.connectionClosed && !_disconnectDialogShowing) {
      _disconnectDialogShowing = true;
      _showDisconnectDialog();
    }
  }

  void _onCreatorServiceChanged() {
    if (!mounted) return;
    final session = ref.read(activeWatchPartyProvider);
    if (session == null) return;
    if (session.isHost) {
      final hasGuests =
          session.creatorService?.activeDataChannels.isNotEmpty ?? false;
      if (hasGuests && !_hasGuestJoinedBefore) {
        setState(() {
          _hasGuestJoinedBefore = true;
        });
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    final session = ref.read(activeWatchPartyProvider);
    session?.chatService.removeListener(_onChatServiceChanged);
    if (session?.isHost == true) {
      session?.creatorService?.removeListener(_onCreatorServiceChanged);
    }
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    _pingTimer?.cancel();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _performSessionCleanup() async {
    final session = ref.read(activeWatchPartyProvider);
    if (session != null) {
      await session.chatService.leaveParty();
      session.chatService.dispose();
    }
    ref.read(activeWatchPartyProvider.notifier).clearSession();
    ref.read(playerAuxiliaryPanelBuilderProvider.notifier).state = null;
    ref.read(playerAuxiliaryPanelVisibleProvider.notifier).state = false;

    final playerState = ref.read(inAppPlayerProvider);
    if (playerState.mode != PlayerWindowMode.fullscreen) {
      ref.read(inAppPlayerProvider.notifier).close();
    }
  }

  Future<void> _explicitLeaveParty() async {
    final session = ref.read(activeWatchPartyProvider);
    if (session == null || session.chatService.connectionClosed) {
      await _performSessionCleanup();
      // In inline mode session is gone → WatchPartyScreen rebuilds to idle UI.
      if (!widget.isInline && mounted) Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: const Text('Leave WatchParty?'),
        content: const Text(
            'Are you sure you want to disconnect from this watch party?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      await _performSessionCleanup();
      if (!widget.isInline && mounted) Navigator.of(context).pop();
    }
  }

  void _showDisconnectDialog() {
    final session = ref.read(activeWatchPartyProvider);
    final msg = session?.chatService.kickMessage ??
        'The peer has disconnected from the watch party.';
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(session?.chatService.kickMessage != null
              ? 'Kicked from Room'
              : 'Connection Lost'),
          content: Text(msg),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await _performSessionCleanup();
                if (!widget.isInline && mounted) Navigator.of(context).pop();
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  void _sendMessage() {
    final session = ref.read(activeWatchPartyProvider);
    if (session == null) return;
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    try {
      session.chatService.sendMessage(text);
      _messageController.clear();
      _scrollToBottom();
      _messageFocusNode.requestFocus();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send: $e')),
      );
    }
  }

  void _sendReaction(String emoji) {
    final session = ref.read(activeWatchPartyProvider);
    if (session == null) return;
    try {
      session.chatService.sendReaction(emoji);
      _scrollToBottom();
      _messageFocusNode.requestFocus();
    } catch (_) {}
  }

  String _buildInviteUrl(GeneralSettings settings, String hostName, String passcode) {
    final jsonStr = jsonEncode({
      'db': settings.watchPartyProjectId.trim(),
      'key': settings.watchPartyAnonKey.trim(),
      'turn_user': settings.watchPartyTurnUsername.trim(),
      'turn_pass': settings.watchPartyTurnPassword.trim(),
    });
    final encryptedCode = WatchPartyCrypto.encrypt(jsonStr, passcode, hostName);
    return '${WatchPartyConfig.redirectUrl}?host=${Uri.encodeComponent(hostName)}&code=${Uri.encodeComponent(encryptedCode)}';
  }

  void _copyInviteLink(GeneralSettings settings, String hostName, String passcode) {
    unawaited(Clipboard.setData(
        ClipboardData(text: _buildInviteUrl(settings, hostName, passcode))));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite link copied to clipboard!')),
    );
  }

  void _showQRDialog(GeneralSettings settings, String hostName, String passcode) {
    final inviteUrl = _buildInviteUrl(settings, hostName, passcode);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: const Text('Invite QR Code'),
        content: SizedBox(
          width: 250,
          height: 250,
          child: Center(
            child: QrImageView(
              data: inviteUrl,
              version: QrVersions.auto,
              size: 200.0,
              gapless: false,
              eyeStyle: QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              dataModuleStyle: QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showDiagnosticsLogs(ActiveWatchPartyState session) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final logs = session.isHost
            ? (session.creatorService?.diagnosticLogs ?? [])
            : (session.chatService.messages
                .where((m) => m['type'] == 'system')
                .map((m) => m['text'] as String)
                .toList());
        final logsToShow =
            logs.isEmpty ? ['No connection diagnostic logs available.'] : logs;
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Connection Diagnostic Logs',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: logsToShow.length,
                  itemBuilder: (context, idx) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      logsToShow[idx],
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Colors.grey),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPeopleDialog(ActiveWatchPartyState session) {
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final guests =
              session.creatorService?.activeDataChannels.keys.toList() ?? [];
          return AlertDialog(
            surfaceTintColor: Colors.transparent,
            title: const Text('Lobby Members'),
            content: SizedBox(
              width: double.maxFinite,
              child: guests.isEmpty
                  ? const Text('No guests currently in the lobby.',
                      style: TextStyle(color: Colors.grey))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: guests.length,
                      itemBuilder: (context, idx) {
                        final guest = guests[idx];
                        return ListTile(
                          title: Text(guest,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          trailing: session.isHost
                              ? IconButton(
                                  icon: Icon(Icons.remove_circle_outline,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary),
                                  tooltip: 'Kick',
                                  onPressed: () {
                                    session.creatorService?.kickGuest(guest);
                                    setDialogState(() {});
                                  },
                                )
                              : null,
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMessageBubble(
      BuildContext context, Map<String, dynamic> msg) {
    final isSystem = msg['type'] == 'system';
    final isReaction = msg['type'] == 'reaction';

    if (isSystem) {
      return Align(
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.5),
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

    if (isReaction) {
      final isMe = msg['isMe'] as bool? ?? false;
      final sender = msg['sender'] as String? ?? (isMe ? 'Me' : 'Friend');
      return Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(isMe ? 'Me' : sender,
                  style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant
                          .withOpacity(0.6))),
              Text(msg['emoji'] as String,
                  style: const TextStyle(fontSize: 36)),
            ],
          ),
        ),
      );
    }

    final isMe = msg['isMe'] as bool? ?? false;
    final sender = msg['sender'] as String? ?? (isMe ? 'You' : 'Friend');

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
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isMe
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16).copyWith(
                topRight:
                    isMe ? const Radius.circular(0) : const Radius.circular(16),
                topLeft:
                    isMe ? const Radius.circular(16) : const Radius.circular(0),
              ),
            ),
            child: Text(
              msg['text'] as String? ?? '',
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
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(activeWatchPartyProvider);
    if (session == null) return const SizedBox.shrink();

    ref.listen<ActiveWatchPartyState?>(activeWatchPartyProvider, (prev, next) {
      if (next == null) return;
      _lastPong = DateTime.now();

      if (next.chatService.connectionClosed && !_disconnectDialogShowing) {
        _disconnectDialogShowing = true;
        _showDisconnectDialog();
      }

      if (next.isHost) {
        final hasGuests =
            next.creatorService?.activeDataChannels.isNotEmpty ?? false;
        if (hasGuests) {
          setState(() {
            _hasGuestJoinedBefore = true;
          });
        }
      }
      _scrollToBottom();
    });

    final settings = ref.read(generalSettingsProvider);
    final messages = session.chatService.messages;
    final isHostWaiting = session.isHost &&
        (session.creatorService?.activeDataChannels.isEmpty ?? true) &&
        !_hasGuestJoinedBefore;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final useNarrowLayout = availableWidth < 360;

        return Scaffold(
          appBar: AppBar(
            // In inline mode there is no route to pop — hide the back arrow.
            automaticallyImplyLeading: !widget.isInline,
            title: Row(
              children: [
                // Connection quality dot
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: _connectionColor,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Text(
                    "${session.hostName}'s Lobby",
                    style: TextStyle(
                      fontSize: useNarrowLayout ? 14.0 : 18.0,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            // Reconnect banner
            bottom: session.chatService.isReconnecting
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(24),
                    child: Container(
                      color: Colors.orange.withOpacity(0.15),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Center(
                        child: Text(
                          'Reconnecting… (attempt ${session.chatService.reconnectAttempt}/${3})',
                          style: const TextStyle(fontSize: 12, color: Colors.orange),
                        ),
                      ),
                    ),
                  )
                : null,
            actions: [
              IconButton(
                icon: Icon(
                  Icons.exit_to_app_rounded,
                  color: Colors.redAccent,
                  size: useNarrowLayout ? 20 : 24,
                ),
                tooltip: 'Leave WatchParty',
                onPressed: _explicitLeaveParty,
                constraints: useNarrowLayout
                    ? const BoxConstraints(minWidth: 32, minHeight: 32)
                    : null,
                padding: useNarrowLayout ? EdgeInsets.zero : const EdgeInsets.all(8.0),
              ),
              if (!useNarrowLayout && session.isHost) ...[
                IconButton(
                  icon: const Icon(Icons.link_rounded),
                  tooltip: 'Copy Invite Link',
                  onPressed: () => _copyInviteLink(
                      settings, session.hostName, session.passcode),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code_2_rounded),
                  tooltip: 'Show QR Code',
                  onPressed: () => _showQRDialog(
                      settings, session.hostName, session.passcode),
                ),
              ],
              PopupMenuButton<String>(
                surfaceTintColor: Colors.transparent,
                iconSize: useNarrowLayout ? 20 : 24,
                constraints: useNarrowLayout
                    ? const BoxConstraints(minWidth: 32, minHeight: 32)
                    : null,
                padding: useNarrowLayout ? EdgeInsets.zero : const EdgeInsets.all(8.0),
                onSelected: (val) {
                  if (val == 'people') _showPeopleDialog(session);
                  if (val == 'logs') _showDiagnosticsLogs(session);
                  if (val == 'link') {
                    _copyInviteLink(settings, session.hostName, session.passcode);
                  }
                  if (val == 'qr') {
                    _showQRDialog(settings, session.hostName, session.passcode);
                  }
                },
                itemBuilder: (context) => [
                  if (useNarrowLayout && session.isHost) ...[
                    const PopupMenuItem(
                      value: 'link',
                      child: Row(
                        children: [
                          Icon(Icons.link_rounded, size: 20),
                          SizedBox(width: 8),
                          Text('Copy Invite Link'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'qr',
                      child: Row(
                        children: [
                          Icon(Icons.qr_code_2_rounded, size: 20),
                          SizedBox(width: 8),
                          Text('Show QR Code'),
                        ],
                      ),
                    ),
                  ],
                  const PopupMenuItem(
                    value: 'people',
                    child: Row(
                      children: [
                        Icon(Icons.people_outline, size: 20),
                        SizedBox(width: 8),
                        Text('Lobby Members'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'logs',
                    child: Row(
                      children: [
                        Icon(Icons.receipt_long_outlined, size: 20),
                        SizedBox(width: 8),
                        Text('Connection Logs'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
      body: Column(
        children: [
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
                        'Lobby Passcode: ${session.passcode}',
                        style: const TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _copyInviteLink(
                                settings, session.hostName, session.passcode),
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('Copy Invite Link'),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: () => _showQRDialog(
                                settings, session.hostName, session.passcode),
                            icon: const Icon(Icons.qr_code_2_rounded, size: 16),
                            label: const Text('Show QR'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            // Chat message list
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: LayoutConstants.spacingMd,
                  vertical: LayoutConstants.spacingSm,
                ),
                itemCount: messages.length,
                itemBuilder: (context, index) =>
                    _buildMessageBubble(context, messages[index]),
              ),
            ),

            // Quick reaction bar
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: _kReactions.map((emoji) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => _sendReaction(emoji),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(emoji,
                            style: const TextStyle(fontSize: 22)),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

            // Text input
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    LayoutConstants.spacingMd,
                    0,
                    LayoutConstants.spacingMd,
                    LayoutConstants.spacingMd),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        focusNode: _messageFocusNode,
                        decoration: const InputDecoration(
                          hintText: 'Type a message...',
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.all(Radius.circular(24)),
                          ),
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
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
              ),
            ),
          ],
        ],
      ),
        );
      },
    );
  }
}
