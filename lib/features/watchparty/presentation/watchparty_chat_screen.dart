import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  final ActiveWatchPartyState session;

  const WatchPartyChatScreen({
    super.key,
    required this.session,
  });

  @override
  ConsumerState<WatchPartyChatScreen> createState() => _WatchPartyChatScreenState();
}

class _WatchPartyChatScreenState extends ConsumerState<WatchPartyChatScreen> {
  bool _disconnectDialogShowing = false;

  @override
  void initState() {
    super.initState();
    widget.session.chatService.addListener(_onChatServiceUpdate);
    
    if (widget.session.isHost) {
      widget.session.chatService.onAllGuestsLeft = () {
        if (!mounted) return;
        ref.read(notificationServiceProvider).showInfo(
          'All guests have left the lobby.',
        );
      };
    }
  }

  @override
  void dispose() {
    widget.session.chatService.removeListener(_onChatServiceUpdate);
    super.dispose();
  }

  void _onChatServiceUpdate() {
    if (!mounted) return;
    final chatService = widget.session.chatService;
    if (chatService.connectionClosed && !_disconnectDialogShowing) {
      _disconnectDialogShowing = true;
      _showDisconnectDialog();
    }
  }

  void _showDisconnectDialog() {
    final chatService = widget.session.chatService;
    final msg = chatService.kickMessage ?? 'The peer has disconnected from the watch party.';

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(chatService.kickMessage != null ? 'Kicked from Room' : 'Connection Lost'),
          content: Text(msg),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                ref.read(activeWatchPartyProvider.notifier).clearSession();
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  String _buildInviteUrl(GeneralSettings settings) {
    final jsonStr = jsonEncode({
      'db': settings.watchPartyProjectId.trim(),
      'key': settings.watchPartyAnonKey.trim(),
      'turn_user': settings.watchPartyTurnUsername.trim(),
      'turn_pass': settings.watchPartyTurnPassword.trim(),
    });
    final encryptedCode = WatchPartyCrypto.encrypt(jsonStr, widget.session.passcode, widget.session.hostName);
    return '${WatchPartyConfig.redirectUrl}?host=${Uri.encodeComponent(widget.session.hostName)}&code=${Uri.encodeComponent(encryptedCode)}';
  }

  void _copyInviteLink() {
    final settings = ref.read(generalSettingsProvider);
    final inviteUrl = _buildInviteUrl(settings);
    Clipboard.setData(ClipboardData(text: inviteUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite link copied to clipboard!')),
    );
  }



  void _showDiagnosticsLogs() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final logs = widget.session.isHost
            ? (widget.session.creatorService?.diagnosticLogs ?? [])
            : (widget.session.chatService.messages.where((m) => m['type'] == 'system').map((m) => m['text'] as String).toList());
        
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
            final guests = widget.session.creatorService?.activeDataChannels.keys.toList() ?? [];
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
                              trailing: widget.session.isHost
                                  ? IconButton(
                                      icon: Icon(Icons.remove_circle_outline, color: Theme.of(context).colorScheme.primary),
                                      tooltip: 'Kick',
                                      onPressed: () {
                                        widget.session.creatorService?.kickGuest(guest);
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

  Future<void> _leaveSessionConfirm() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(widget.session.isHost ? 'End WatchParty?' : 'Leave WatchParty?'),
        content: Text(widget.session.isHost
            ? 'Are you sure you want to end and disconnect this watch party?'
            : 'Are you sure you want to disconnect from this watch party?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(widget.session.isHost ? 'End Party' : 'Leave'),
          ),
        ],
      ),
    );

    if (leave == true) {
      await widget.session.chatService.leaveParty();
      ref.read(activeWatchPartyProvider.notifier).clearSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              )
            : null,
        title: Text('${widget.session.hostName}\'s Lobby'),
        actions: [
          IconButton(
            icon: const Icon(Icons.link_rounded),
            tooltip: 'Copy Invite Link',
            onPressed: _copyInviteLink,
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new_rounded),
            color: Colors.redAccent,
            tooltip: widget.session.isHost ? 'End Lobby & Leave' : 'Leave Lobby',
            onPressed: _leaveSessionConfirm,
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
        chatService: widget.session.chatService,
        isHost: widget.session.isHost,
        passcode: widget.session.passcode,
        creatorService: widget.session.creatorService,
        onCopyInviteLink: _copyInviteLink,
      ),
    );
  }
}
