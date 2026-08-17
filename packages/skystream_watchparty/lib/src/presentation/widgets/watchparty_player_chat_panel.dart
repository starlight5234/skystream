import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../config/watchparty_config.dart';
import '../../service/watchparty_crypto.dart';
import '../../config/watchparty_settings.dart';
import '../../data/supabase_watchparty_database.dart';
import '../../service/watchparty_chat_service.dart';
import '../../service/watchparty_creator_service.dart';
import '../../service/watchparty_joiner_service.dart';
import '../providers/active_watchparty_provider.dart';
import 'watchparty_chat_body.dart';

class WatchPartyPlayerChatPanel extends ConsumerStatefulWidget {
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
  ConsumerState<WatchPartyPlayerChatPanel> createState() => _WatchPartyPlayerChatPanelState();
}

class _WatchPartyPlayerChatPanelState extends ConsumerState<WatchPartyPlayerChatPanel> {
  // Join/Host Setup State
  final _joinHostController = TextEditingController();
  final _joinPasscodeController = TextEditingController();
  WatchPartyCreatorService? _creatorService;
  WatchPartyJoinerService? _joinerService;
  bool _setupLoading = false;
  String _setupStatus = '';
  String? _setupError;
  String? _lobbyPasscode;

  ActiveWatchPartyState? _subscribedSession;

  @override
  void initState() {
    super.initState();
    _updateSessionSubscription();
  }

  @override
  void didUpdateWidget(WatchPartyPlayerChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateSessionSubscription();
  }

  void _updateSessionSubscription() {
    if (_subscribedSession != widget.session) {
      _subscribedSession?.chatService.removeListener(_onChatServiceStateChanged);
      _subscribedSession = widget.session;
      _subscribedSession?.chatService.addListener(_onChatServiceStateChanged);
    }
  }

  void _onChatServiceStateChanged() {
    if (!mounted) return;
    final session = widget.session;
    if (session == null) return;

    if (session.chatService.connectionClosed) {
      session.chatService.removeListener(_onChatServiceStateChanged);
      _subscribedSession = null;

      final msg = session.chatService.kickMessage ?? 'The watch party connection was closed.';
      widget.onShowNotification?.call(msg);
      ref.read(activeWatchPartyProvider.notifier).clearSession();
      return;
    }

    setState(() {});
  }

  @override
  void dispose() {
    _subscribedSession?.chatService.removeListener(_onChatServiceStateChanged);
    _joinHostController.dispose();
    _joinPasscodeController.dispose();
    _creatorService?.removeListener(_onCreatorUpdate);
    _creatorService?.dispose();
    _joinerService?.removeListener(_onJoinerUpdate);
    _joinerService?.dispose();
    super.dispose();
  }

  void _onCreatorUpdate() {
    if (!mounted) return;
    final service = _creatorService;
    if (service == null) return;

    if (service.error != null) {
      final errorMsg = service.error!;
      _creatorService?.removeListener(_onCreatorUpdate);
      _creatorService = null;
      setState(() {
        _setupLoading = false;
        _setupError = errorMsg;
      });
      return;
    }

    if (service.lobbyReady) {
      _onP2PConnected(
        peerConnection: null,
        dataChannel: null,
        isHost: true,
        hostName: 'Host',
      );
      return;
    }

    setState(() {
      _setupLoading = service.isLoading;
      _setupStatus = service.statusMessage;
    });
  }

  void _onJoinerUpdate() {
    if (!mounted) return;
    final service = _joinerService;
    if (service == null) return;

    if (service.error != null) {
      final errorMsg = service.error!;
      _joinerService?.removeListener(_onJoinerUpdate);
      _joinerService = null;
      setState(() {
        _setupLoading = false;
        _setupError = errorMsg;
      });
      return;
    }

    if (service.connectionSuccess) {
      _onP2PConnected(
        peerConnection: service.peerConnection!,
        dataChannel: service.dataChannel!,
        isHost: false,
        hostName: _joinHostController.text.trim(),
      );
      return;
    }

    setState(() {
      _setupLoading = service.isLoading;
      _setupStatus = service.statusMessage;
    });
  }

  Future<void> _onP2PConnected({
    RTCPeerConnection? peerConnection,
    RTCDataChannel? dataChannel,
    required bool isHost,
    required String hostName,
  }) async {
    setState(() {
      _setupLoading = false;
      _setupError = null;
    });

    _creatorService?.removeListener(_onCreatorUpdate);
    _joinerService?.removeListener(_onJoinerUpdate);

    final settings = await WatchPartySettings.loadFromPrefs();
    final passcode = isHost ? (_creatorService?.roomPasscode ?? '') : (_lobbyPasscode ?? '');
    final resolvedUserName = settings.username.isNotEmpty ? settings.username : 'User';

    final chatService = WatchPartyChatService(
      peerConnection: peerConnection,
      dataChannel: dataChannel,
      creatorService: isHost ? _creatorService : null,
      joinerService: isHost ? null : _joinerService,
      database: ref.read(watchPartyDatabaseProvider),
      isHost: isHost,
      hostName: hostName,
      userName: resolvedUserName,
      passcode: passcode,
    );

    ref.read(activeWatchPartyProvider.notifier).setActiveSession(
      ActiveWatchPartyState(
        peerConnection: peerConnection,
        dataChannel: dataChannel,
        creatorService: isHost ? _creatorService : null,
        database: ref.read(watchPartyDatabaseProvider),
        isHost: isHost,
        hostName: hostName,
        userName: resolvedUserName,
        passcode: passcode,
        chatService: chatService,
      ),
    );
    ref.read(watchPartyLandscapeChatProvider.notifier).setVisible(true);
  }

  Future<void> _executeStartHost() async {
    final settings = await WatchPartySettings.loadFromPrefs();
    final database = ref.read(watchPartyDatabaseProvider);
    final name = settings.username.isNotEmpty ? settings.username : 'Host';

    setState(() {
      _setupLoading = true;
      _setupError = null;
      _setupStatus = 'Initializing WebRTC connection...';
    });

    _creatorService?.removeListener(_onCreatorUpdate);
    _creatorService?.dispose();

    _creatorService = WatchPartyCreatorService(settings, database);
    _creatorService!.addListener(_onCreatorUpdate);
    unawaited(_creatorService!.startHosting(name));
  }

  Future<void> _executeJoin() async {
    final hostName = _joinHostController.text.trim();
    final passcode = _joinPasscodeController.text.trim();

    if (hostName.isEmpty || passcode.isEmpty) {
      setState(() {
        _setupError = 'Host name and Passcode are required.';
      });
      return;
    }

    final settings = await WatchPartySettings.loadFromPrefs();
    final database = ref.read(watchPartyDatabaseProvider);
    final guestName = settings.username.isNotEmpty ? settings.username : 'Guest';

    setState(() {
      _setupLoading = true;
      _setupError = null;
      _setupStatus = 'Checking for lobby...';
      _lobbyPasscode = passcode;
    });

    _joinerService?.removeListener(_onJoinerUpdate);
    _joinerService?.dispose();

    _joinerService = WatchPartyJoinerService(settings, database);
    _joinerService!.addListener(_onJoinerUpdate);
    unawaited(_joinerService!.startJoining(hostName, guestName, passcode));
  }

  void _cancelConnection() {
    _creatorService?.cancelHosting();
    _joinerService?.cancelJoining();
    setState(() {
      _setupLoading = false;
      _setupError = null;
      _setupStatus = '';
    });
  }

  // Active Session UI Helpers
  Future<String> _buildInviteUrl() async {
    final session = widget.session!;
    final settings = await WatchPartySettings.loadFromPrefs();
    final jsonStr = jsonEncode({
      'db': settings.projectId.trim(),
      'key': settings.anonKey.trim(),
      'turn_user': settings.turnUsername.trim(),
      'turn_pass': settings.turnPassword.trim(),
    });
    final encryptedCode = WatchPartyCrypto.encrypt(jsonStr, session.passcode, session.hostName);
    return '${WatchPartyConfig.redirectUrl}?host=${Uri.encodeComponent(session.hostName)}&code=${Uri.encodeComponent(encryptedCode)}';
  }

  Future<void> _copyInviteLink() async {
    final inviteUrl = await _buildInviteUrl();
    await Clipboard.setData(ClipboardData(text: inviteUrl));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invite link copied to clipboard!')),
      );
    }
  }

  void _showPeopleDialog() {
    final session = widget.session!;
    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final guests = session.creatorService?.activeDataChannels.keys.toList() ?? [];
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
                              trailing: session.isHost
                                  ? IconButton(
                                      icon: Icon(Icons.remove_circle_outline, color: Theme.of(context).colorScheme.primary),
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

  void _showDiagnosticsLogs() {
    final session = widget.session!;
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final logs = session.isHost
            ? (session.creatorService?.diagnosticLogs ?? [])
            : (session.chatService.messages.where((m) => m['type'] == 'system').map((m) => m['text'] as String).toList());
        
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

  Future<void> _leaveSessionConfirm() async {
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

    if (leave == true && mounted) {
      await widget.session!.chatService.leaveParty();
      ref.read(activeWatchPartyProvider.notifier).clearSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    final isPortrait = orientation == Orientation.portrait;
    final session = widget.session;

    return Container(
      width: isPortrait ? double.infinity : 320,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          left: isPortrait
              ? BorderSide.none
              : BorderSide(color: Colors.grey.withValues(alpha: 0.3), width: 1.0),
          top: isPortrait
              ? BorderSide(color: Colors.grey.withValues(alpha: 0.3), width: 1.0)
              : BorderSide.none,
        ),
      ),
      child: session != null
          ? Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                      const SizedBox(width: 8),
                      const Text(
                        'Chat',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.link_rounded, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Copy Invite Link',
                        onPressed: _copyInviteLink,
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.power_settings_new_rounded, size: 18),
                        color: Colors.redAccent,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: session.isHost ? 'End Lobby & Leave' : 'Leave Lobby',
                        onPressed: _leaveSessionConfirm,
                      ),
                      const SizedBox(width: 4),
                      PopupMenuButton<String>(
                        surfaceTintColor: Colors.transparent,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.more_vert_rounded, size: 18),
                        onSelected: (val) {
                          if (val == 'passcode') {
                            if (session.passcode.isNotEmpty) {
                              Clipboard.setData(ClipboardData(text: session.passcode));
                            }
                          } else if (val == 'people') {
                            _showPeopleDialog();
                          } else if (val == 'logs') {
                            _showDiagnosticsLogs();
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'passcode',
                            child: Row(
                              children: [
                                Icon(Icons.key_outlined, size: 18),
                                SizedBox(width: 8),
                                Text('Copy Passcode'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'people',
                            child: Row(
                              children: [
                                Icon(Icons.people_outline, size: 18),
                                SizedBox(width: 8),
                                Text('People'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'logs',
                            child: Row(
                              children: [
                                Icon(Icons.receipt_long_outlined, size: 18),
                                SizedBox(width: 8),
                                Text('Connection Logs'),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (!isPortrait) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            if (widget.onClose != null) {
                              widget.onClose!();
                            } else {
                              ref.read(watchPartyLandscapeChatProvider.notifier).toggle();
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: WatchPartyChatBody(
                    chatService: session.chatService,
                    isHost: session.isHost,
                    passcode: session.passcode,
                    creatorService: session.creatorService,
                    onCopyInviteLink: _copyInviteLink,
                    onJoinMediaStream: widget.onJoinMediaStream,
                  ),
                ),
              ],
            )
          : Stack(
              children: [
                Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.share_outlined, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'Watch Party Setup',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () {
                              if (widget.onClose != null) {
                                widget.onClose!();
                              } else {
                                ref.read(watchPartyLandscapeChatProvider.notifier).toggle();
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_setupError != null) ...[
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                                ),
                                child: Text(
                                  _setupError!,
                                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                            Text(
                              'Host a Watch Party',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Start hosting a Watch Party so others can sync and watch this stream with you.',
                              style: TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: _setupLoading ? null : _executeStartHost,
                              icon: const Icon(Icons.add_to_queue_rounded, size: 18),
                              label: const Text('Host Lobby'),
                            ),
                            const Divider(height: 32),
                            Text(
                              'Join a Watch Party',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Enter a host\'s nickname and room passcode to join their synchronized session.',
                              style: TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _joinHostController,
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: 'Host Nickname',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _joinPasscodeController,
                              style: const TextStyle(fontSize: 13),
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: 'Passcode',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed: _setupLoading ? null : _executeJoin,
                              icon: const Icon(Icons.group_add_rounded, size: 18),
                              label: const Text('Join watch party'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (_setupLoading)
                  Container(
                    color: Colors.black54,
                    child: Center(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 32),
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.1)),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 24),
                            Text(
                              _setupStatus,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton(
                              onPressed: _cancelConnection,
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
