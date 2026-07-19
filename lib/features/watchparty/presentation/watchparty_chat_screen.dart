import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../core/utils/layout_constants.dart';
import '../../settings/presentation/general_settings_provider.dart';
import '../data/watchparty_database.dart';
import '../config/watchparty_config.dart';
import '../service/watchparty_chat_service.dart';
import '../service/watchparty_creator_service.dart';
import '../service/watchparty_joiner_service.dart';
import '../service/watchparty_crypto.dart';
import 'providers/active_watchparty_provider.dart';
import '../../../core/services/notification_service.dart';
import 'widgets/watchparty_chat_body.dart';

class WatchPartyChatScreen extends ConsumerStatefulWidget {
  final RTCPeerConnection? peerConnection;
  final RTCDataChannel? dataChannel;
  final WatchPartyCreatorService? creatorService;
  final WatchPartyJoinerService? joinerService;
  final WatchPartyDatabase database;
  final bool isHost;
  final String hostName;
  final String userName;
  final String passcode;

  const WatchPartyChatScreen({
    super.key,
    this.peerConnection,
    this.dataChannel,
    this.creatorService,
    this.joinerService,
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
  bool _hasGuestJoinedBefore = false;

  @override
  void initState() {
    super.initState();
    _chatService = WatchPartyChatService(
      peerConnection: widget.peerConnection,
      dataChannel: widget.dataChannel,
      creatorService: widget.creatorService,
      joinerService: widget.joinerService,
      database: widget.database,
      isHost: widget.isHost,
      hostName: widget.hostName,
      userName: widget.userName,
      passcode: widget.passcode,
    );
    _chatService.addListener(_onChatServiceUpdate);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(activeWatchPartyProvider.notifier).setActiveSession(
        ActiveWatchPartyState(
          peerConnection: widget.peerConnection,
          dataChannel: widget.dataChannel,
          creatorService: widget.creatorService,
          database: widget.database,
          isHost: widget.isHost,
          hostName: widget.hostName,
          userName: widget.userName,
          passcode: widget.passcode,
          chatService: _chatService,
        ),
      );
    });

    if (widget.isHost) {
      _chatService.onAllGuestsLeft = () {
        if (!mounted) return;
        ref.read(notificationServiceProvider).showInfo(
          'All guests have left the lobby.',
        );
      };
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _chatService.removeListener(_onChatServiceUpdate);
    _chatService.dispose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(activeWatchPartyProvider.notifier).clearSession();
    });
    super.dispose();
  }

  void _onChatServiceUpdate() {
    if (!mounted) return;
    if (_chatService.connectionClosed && !_disconnectDialogShowing) {
      _disconnectDialogShowing = true;
      _showDisconnectDialog();
    }

    if (widget.isHost) {
      final hasActiveGuests = widget.creatorService?.activeDataChannels.isNotEmpty ?? false;
      if (hasActiveGuests) {
        _hasGuestJoinedBefore = true;
      }
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
    final msg = _chatService.kickMessage ?? 'The peer has disconnected from the watch party.';
    final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;

    if (!isCurrentRoute) {
      // Player screen is on top — use a subtle toast instead of a blocking dialog
      ref.read(notificationServiceProvider).showInfo(msg);
      Future<void>.delayed(const Duration(milliseconds: 1500), () async {
        if (!mounted) return;
        await _chatService.leaveParty();
        _safePop();
      });
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(_chatService.kickMessage != null ? 'Kicked from Room' : 'Connection Lost'),
          content: Text(msg),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await _chatService.leaveParty();
                _safePop();
              },
              child: const Text('OK'),
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

  void _showDiagnosticsLogs() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final logs = widget.isHost
            ? (widget.creatorService?.diagnosticLogs ?? [])
            : (_chatService.messages.where((m) => m['type'] == 'system').map((m) => m['text'] as String).toList());
        
        final logsToShow = logs.isEmpty ? ['No connection diagnostic logs available.'] : logs;

        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connection Diagnostic Logs',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: logsToShow.length,
                  itemBuilder: (context, idx) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      logsToShow[idx],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey),
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

  void _showPeopleDialog() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final guests = widget.creatorService?.activeDataChannels.keys.toList() ?? [];
            final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

            return AlertDialog(
              surfaceTintColor: Colors.transparent,
              title: const Text('Lobby Members'),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isDesktop ? 400.0 : double.infinity,
                ),
                child: SizedBox(
                  width: isDesktop ? 400.0 : double.maxFinite,
                  child: guests.isEmpty
                      ? const Text('No guests currently in the lobby.', style: TextStyle(color: Colors.grey))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: guests.length,
                          itemBuilder: (context, idx) {
                            final guest = guests[idx];
                            return ListTile(
                              title: Text(
                                guest,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: widget.isHost
                                  ? IconButton(
                                      icon: Icon(Icons.remove_circle_outline, color: Theme.of(context).colorScheme.primary),
                                      tooltip: 'Kick',
                                      onPressed: () {
                                        widget.creatorService?.kickGuest(guest);
                                        setDialogState(() {});
                                      },
                                    )
                                  : null,
                            );
                          },
                        ),
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
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
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              final shouldPop = await _onWillPop();
              if (shouldPop && mounted) {
                _safePop();
              }
            },
          ),
          title: Text('${widget.hostName}\'s Lobby'),
          actions: [
            IconButton(
              icon: const Icon(Icons.link_rounded),
              tooltip: 'Copy Invite Link',
              onPressed: _copyInviteLink,
            ),
            IconButton(
              icon: const Icon(Icons.qr_code_2_rounded),
              tooltip: 'Show QR Code',
              onPressed: _showQRDialog,
            ),
            IconButton(
              icon: const Icon(Icons.power_settings_new_rounded),
              color: Colors.redAccent,
              tooltip: widget.isHost ? 'End Lobby & Leave' : 'Leave Lobby',
              onPressed: () async {
                final shouldPop = await _onWillPop();
                if (shouldPop && mounted) {
                  _safePop();
                }
              },
            ),
            PopupMenuButton<String>(
              surfaceTintColor: Colors.transparent,
              onSelected: (val) {
                if (val == 'people') {
                  _showPeopleDialog();
                } else if (val == 'logs') {
                  _showDiagnosticsLogs();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'people',
                  child: Row(
                    children: [
                      Icon(Icons.people_outline, size: 20),
                      SizedBox(width: 8),
                      Text('People'),
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
        body: WatchPartyChatBody(
          chatService: _chatService,
          isHost: widget.isHost,
          passcode: widget.passcode,
          creatorService: widget.creatorService,
          onCopyInviteLink: _copyInviteLink,
          onShowQRDialog: _showQRDialog,
        ),
      ),
    );
  }
}
