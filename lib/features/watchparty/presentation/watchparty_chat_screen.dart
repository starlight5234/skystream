import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../core/utils/layout_constants.dart';
import '../../settings/presentation/general_settings_provider.dart';
import '../data/watchparty_database.dart';
import '../data/supabase_watchparty_database.dart';
import '../config/watchparty_config.dart';
import '../service/watchparty_chat_service.dart';
import '../service/watchparty_crypto.dart';

class WatchPartyChatScreen extends ConsumerStatefulWidget {
  final RTCPeerConnection peerConnection;
  final RTCDataChannel dataChannel;
  final WatchPartyDatabase database;
  final bool isHost;
  final String hostName;
  final String userName;
  final String passcode;

  const WatchPartyChatScreen({
    super.key,
    required this.peerConnection,
    required this.dataChannel,
    required this.database,
    required this.isHost,
    required this.hostName,
    required this.userName,
    required this.passcode,
  });

  @override
  ConsumerState<WatchPartyChatScreen> createState() => _WatchPartyChatScreenState();
}

class _WatchPartyChatScreenState extends ConsumerState<WatchPartyChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  late final WatchPartyChatService _chatService;
  bool _canPop = false;
  bool _disconnectDialogShowing = false;

  @override
  void initState() {
    super.initState();
    _chatService = WatchPartyChatService(
      peerConnection: widget.peerConnection,
      dataChannel: widget.dataChannel,
      database: widget.database,
      isHost: widget.isHost,
      hostName: widget.hostName,
      userName: widget.userName,
      passcode: widget.passcode,
    );
    _chatService.addListener(_onChatServiceUpdate);
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _chatService.removeListener(_onChatServiceUpdate);
    _chatService.dispose();
    super.dispose();
  }

  void _onChatServiceUpdate() {
    if (!mounted) return;
    if (_chatService.connectionClosed && !_disconnectDialogShowing) {
      _disconnectDialogShowing = true;
      _showDisconnectDialog();
    }
    setState(() {});
    _scrollToBottom();
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    try {
      _chatService.sendMessage(text);
      _messageController.clear();
      _scrollToBottom();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send: $e')),
      );
    }
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

  void _safePop() {
    setState(() {
      _canPop = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  void _showDisconnectDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: const Text('Connection Lost'),
          content: const Text('The peer has disconnected from the watch party.'),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(context); // close dialog
                await _chatService.leaveParty();
                _safePop(); // exit chat screen safely
              },
              child: const Text('Leave'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _onWillPop() async {
    if (_chatService.connectionClosed) {
      return true;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: const Text('Leave WatchParty?'),
        content: const Text('Are you sure you want to disconnect from this watch party?'),
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

    if (leave == true) {
      await _chatService.leaveParty();
      return true;
    }
    return false;
  }

  String _buildInviteUrl(GeneralSettings settings) {
    final jsonStr = jsonEncode({
      'db': settings.watchPartyProjectId.trim(),
      'key': settings.watchPartyAnonKey.trim(),
      'turn_user': settings.watchPartyTurnUsername.trim(),
      'turn_pass': settings.watchPartyTurnPassword.trim(),
    });
    final encryptedCode = WatchPartyCrypto.encrypt(jsonStr, widget.passcode, widget.hostName);
    return '${WatchPartyConfig.redirectUrl}?host=${Uri.encodeComponent(widget.hostName)}&code=${Uri.encodeComponent(encryptedCode)}';
  }

  void _copyInviteLink() {
    final settings = ref.read(generalSettingsProvider);
    final inviteUrl = _buildInviteUrl(settings);

    unawaited(Clipboard.setData(ClipboardData(text: inviteUrl)));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite link copied to clipboard!')),
    );
  }

  void _showQRDialog() {
    final settings = ref.read(generalSettingsProvider);
    final inviteUrl = _buildInviteUrl(settings);

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

  @override
  Widget build(BuildContext context) {
    final messages = _chatService.messages;

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) {
          _safePop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.hostName}\'s Lobby'),
          actions: [
            if (widget.isHost) ...[
              IconButton(
                icon: const Icon(Icons.qr_code_rounded),
                tooltip: 'Show QR Code',
                onPressed: _showQRDialog,
              ),
              IconButton(
                icon: const Icon(Icons.share_rounded),
                tooltip: 'Copy Invite Link',
                onPressed: _copyInviteLink,
              ),
            ],
          ],
        ),
        body: Column(
          children: [
            if (widget.isHost && messages.isEmpty)
              Card(
                margin: const EdgeInsets.all(LayoutConstants.spacingMd),
                child: Padding(
                  padding: const EdgeInsets.all(LayoutConstants.spacingMd),
                  child: Column(
                    children: [
                      const Text(
                        'P2P Connection Established!',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Share this room with your friend so they can join you.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton.icon(
                            onPressed: _copyInviteLink,
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('Copy Link'),
                          ),
                          ElevatedButton.icon(
                            onPressed: _showQRDialog,
                            icon: const Icon(Icons.qr_code_2_rounded, size: 16),
                            label: const Text('Show QR'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
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
                  final isMe = msg['isMe'] as bool;
                  final sender = msg['sender'] as String? ?? (isMe ? 'You' : 'Friend');

                  return Align(
                    alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
                          child: Text(
                            sender,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.6),
                            ),
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: isMe
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12).copyWith(
                              bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(12),
                              bottomLeft: isMe ? const Radius.circular(12) : const Radius.circular(0),
                            ),
                          ),
                          child: Text(
                            msg['text'] as String,
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
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(LayoutConstants.spacingMd),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        decoration: const InputDecoration(
                          hintText: 'Type a message...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(24)),
                          ),
                          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
        ),
      ),
    );
  }
}
