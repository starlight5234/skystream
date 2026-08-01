import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../data/watchparty_database.dart';
import '../data/supabase_watchparty_database.dart';
import '../config/watchparty_config.dart';
import '../config/watchparty_settings.dart';
import '../service/watchparty_creator_service.dart';
import '../service/watchparty_joiner_service.dart';
import '../service/watchparty_crypto.dart';
import '../service/watchparty_chat_service.dart';
import 'watchparty_chat_screen.dart';
import 'providers/active_watchparty_provider.dart';

void showWatchPartyUsernameDialog(BuildContext context, WidgetRef ref) {
  final settings = ref.read(watchPartySettingsProvider);
  final controller = TextEditingController(text: settings.watchPartyUsername);

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('WatchParty Username'),
      content: TextField(
        controller: controller,
        decoration: const InputDecoration(
          labelText: 'Username',
          hintText: 'Enter your name',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            final name = controller.text.trim();
            if (name.isNotEmpty) {
              await ref.read(watchPartySettingsProvider.notifier).update(username: name);
            }
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class WatchPartyScreen extends ConsumerStatefulWidget {
  final String? host;
  final String? code;
  final String? passcode;
  final void Function(Map<String, dynamic> mediaPayload)? onJoinMediaStream;

  const WatchPartyScreen({
    super.key,
    this.host,
    this.code,
    this.passcode,
    this.onJoinMediaStream,
  });

  @override
  ConsumerState<WatchPartyScreen> createState() => _WatchPartyScreenState();
}

class _WatchPartyScreenState extends ConsumerState<WatchPartyScreen> {
  final _joinController = TextEditingController();
  
  bool _isLoading = false;
  String _statusMessage = '';
  bool _isHosting = false;
  String? _activeHostName;
  WatchPartyDatabase? _activeDatabase;
  String? _lobbyPasscode;

  WatchPartyCreatorService? _creatorService;
  WatchPartyJoinerService? _joinerService;

  @override
  void initState() {
    super.initState();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.host != null && widget.code != null) {
        _handleDeepLinkJoin();
      }
    });
  }

  @override
  void didUpdateWidget(WatchPartyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.host != null && widget.code != null &&
        (widget.host != oldWidget.host || widget.code != oldWidget.code || widget.passcode != oldWidget.passcode)) {
      _handleDeepLinkJoin();
    }
  }

  @override
  void dispose() {
    _joinController.dispose();
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
      _showError(errorMsg);
      return;
    }

    if (service.lobbyReady) {
      _onP2PConnected(
        peerConnection: null,
        dataChannel: null,
        isHost: true,
        hostName: _activeHostName ?? 'Host',
      );
      return;
    }

    setState(() {
      _isLoading = service.isLoading;
      _statusMessage = service.statusMessage;
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
      _showError(errorMsg);
      return;
    }

    if (service.connectionSuccess) {
      _onP2PConnected(
        peerConnection: service.peerConnection!,
        dataChannel: service.dataChannel!,
        isHost: false,
        hostName: widget.host ?? _joinController.text.trim(),
      );
      return;
    }

    setState(() {
      _isLoading = service.isLoading;
      _statusMessage = service.statusMessage;
    });
  }

  void _onP2PConnected({
    RTCPeerConnection? peerConnection,
    RTCDataChannel? dataChannel,
    required bool isHost,
    required String hostName,
  }) {
    setState(() {
      _isLoading = false;
    });

    _creatorService?.removeListener(_onCreatorUpdate);
    _joinerService?.removeListener(_onJoinerUpdate);

    final settings = ref.read(watchPartySettingsProvider);
    final passcode = isHost ? (_creatorService?.roomPasscode ?? '') : (_lobbyPasscode ?? '');
    final resolvedUserName = settings.watchPartyUsername;

    final chatService = WatchPartyChatService(
      peerConnection: peerConnection,
      dataChannel: dataChannel,
      creatorService: isHost ? _creatorService : null,
      joinerService: isHost ? null : _joinerService,
      database: _activeDatabase ?? ref.read(watchPartyDatabaseProvider),
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
        database: _activeDatabase ?? ref.read(watchPartyDatabaseProvider),
        isHost: isHost,
        hostName: hostName,
        userName: resolvedUserName,
        passcode: passcode,
        chatService: chatService,
      ),
    );

    // Retain _creatorService and _joinerService so reconnection handshake can send new SDP offer
    setState(() {
      _isLoading = false;
    });
  }

  String? _lastHandledCode;

  Future<void> _handleDeepLinkJoin({String? host, String? code, String? passcode}) async {
    final targetHost = host ?? widget.host;
    final targetCode = code ?? widget.code;
    final targetPasscode = passcode ?? widget.passcode;
    
    if (targetHost == null || targetCode == null || targetCode.isEmpty) return;
    if (!mounted) return;

    if (_lastHandledCode == targetCode) return;

    final activeSession = ref.read(activeWatchPartyProvider);
    if (activeSession != null) {
      if (activeSession.hostName == targetHost) return;

      final leaveConfirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: const Text('Switch WatchParty?'),
          content: Text('You are currently in ${activeSession.hostName}\'s watch party. Would you like to leave and join $targetHost\'s lobby?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('Leave & Join'),
            ),
          ],
        ),
      );

      if (leaveConfirm != true) {
        return;
      }

      await activeSession.chatService.leaveParty();
      ref.read(activeWatchPartyProvider.notifier).clearSession();
    }

    _lastHandledCode = targetCode;

    if (targetPasscode != null && targetPasscode.isNotEmpty) {
      try {
        final decryptedJson = WatchPartyCrypto.decrypt(targetCode, targetPasscode, targetHost);
        final parsed = jsonDecode(decryptedJson) as Map<String, dynamic>;

        final db = parsed['db'] as String;
        final key = parsed['key'] as String;
        final turnUser = parsed['turn_user'] as String?;
        final turnPass = parsed['turn_pass'] as String?;
        _lobbyPasscode = targetPasscode;

        setState(() {
          _isLoading = true;
          _isHosting = false;
          _statusMessage = 'Connecting to signaling channel...';
        });

        final settings = ref.read(watchPartySettingsProvider);
        final dbProvider = SupabaseWatchPartyDatabase(
          settings: settings,
          customId: db,
          customKey: key,
        );

        if (!dbProvider.isConfigured()) {
          _showError('Failed to initialize database client from link.');
          return;
        }

        _activeDatabase = dbProvider;
        _joinerService?.removeListener(_onJoinerUpdate);
        _joinerService?.dispose();

        _joinerService = WatchPartyJoinerService(settings, dbProvider);
        _joinerService!.addListener(_onJoinerUpdate);
        unawaited(_joinerService!.startJoining(
          targetHost,
          settings.watchPartyUsername,
          targetPasscode,
          customTurnUsername: turnUser,
          customTurnPassword: turnPass,
        ));
        return;
      } catch (_) {}
    }
    
    final passcodeController = TextEditingController();
    bool obscureText = true;
    String? dialogErrorText;
    
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text('Join $targetHost\'s Lobby'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the 6-character room passcode to decrypt the database connection settings and join:',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passcodeController,
                obscureText: obscureText,
                decoration: InputDecoration(
                  labelText: 'Lobby Passcode',
                  errorText: dialogErrorText,
                  border: const OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.outline,
                      width: 1.0,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2.0,
                    ),
                  ),
                  labelStyle: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscureText ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setDialogState(() {
                        obscureText = !obscureText;
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                setState(() {
                  _isLoading = false;
                });
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final passcode = passcodeController.text.trim();
                if (passcode.isEmpty) {
                  setDialogState(() {
                    dialogErrorText = 'Passcode cannot be empty.';
                  });
                  return;
                }

                setDialogState(() {
                  dialogErrorText = null;
                });

                try {
                  final decryptedJson = WatchPartyCrypto.decrypt(targetCode, passcode, targetHost);
                  final parsed = jsonDecode(decryptedJson) as Map<String, dynamic>;
                  
                  final db = parsed['db'] as String;
                  final key = parsed['key'] as String;
                  final turnUser = parsed['turn_user'] as String?;
                  final turnPass = parsed['turn_pass'] as String?;
                  _lobbyPasscode = passcode;

                  Navigator.pop(context);
                  
                  setState(() {
                    _isLoading = true;
                    _isHosting = false;
                    _statusMessage = 'Connecting to database...';
                  });

                  final settings = ref.read(watchPartySettingsProvider);
                  
                  final dbProvider = SupabaseWatchPartyDatabase(
                    settings: settings,
                    customId: db,
                    customKey: key,
                  );

                  if (!dbProvider.isConfigured()) {
                    _showError('Failed to initialize database client from link.');
                    return;
                  }

                  _activeDatabase = dbProvider;
                  setState(() {
                    _isLoading = true;
                    _statusMessage = 'Checking for lobby...';
                  });

                  _joinerService?.removeListener(_onJoinerUpdate);
                  _joinerService?.dispose();

                  _joinerService = WatchPartyJoinerService(settings, dbProvider);
                  _joinerService!.addListener(_onJoinerUpdate);
                  unawaited(_joinerService!.startJoining(
                    targetHost,
                    settings.watchPartyUsername,
                    passcode,
                    customTurnUsername: turnUser,
                    customTurnPassword: turnPass,
                  ));
                } catch (e) {
                  setDialogState(() {
                    dialogErrorText = 'Incorrect passcode. Please try again.';
                  });
                }
              },
              child: const Text('Join'),
            ),
          ],
        ),
      ),
    );
  }

  void _startHost() {
    final passcodeController = TextEditingController();
    bool obscureText = true;
    
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: const Text('Host WatchParty'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Set a custom passcode (6-8 characters) or leave blank to auto-generate one.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passcodeController,
                obscureText: obscureText,
                decoration: InputDecoration(
                  labelText: 'Passcode (Optional)',
                  hintText: 'e.g. MYPARTY',
                  border: const OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.outline,
                      width: 1.0,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2.0,
                    ),
                  ),
                  labelStyle: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscureText ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setDialogState(() {
                        obscureText = !obscureText;
                      });
                    },
                  ),
                ),
                inputFormatters: [
                  LengthLimitingTextInputFormatter(8),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final passcode = passcodeController.text.trim();
                if (passcode.isNotEmpty && (passcode.length < 6 || passcode.length > 8)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Passcode must be between 6 and 8 characters.')),
                  );
                  return;
                }
                Navigator.pop(context);
                _executeStartHost(passcode.isEmpty ? null : passcode);
              },
              child: const Text('Host'),
            ),
          ],
        ),
      ),
    );
  }

  void _executeStartHost(String? passcode) {
    if (_isLoading) return;
    final settings = ref.read(watchPartySettingsProvider);
    final database = ref.read(watchPartyDatabaseProvider);
    final name = settings.watchPartyUsername;

    _activeDatabase = database;
    _isHosting = true;
    _isLoading = true;
    _activeHostName = name;
    _statusMessage = 'Initializing WebRTC connection...';
    setState(() {});

    _creatorService?.removeListener(_onCreatorUpdate);
    _creatorService?.dispose();

    _creatorService = WatchPartyCreatorService(settings, database);
    _creatorService!.addListener(_onCreatorUpdate);
    unawaited(_creatorService!.startHosting(name, customPasscode: passcode));
  }

  void _handleTextJoin() {
    final input = _joinController.text.trim();
    if (input.isEmpty) return;

    if (input.startsWith('skystream://') || input.startsWith('http://') || input.startsWith('https://')) {
      try {
        final uri = Uri.parse(input);
        final host = uri.queryParameters['host'];
        final code = uri.queryParameters['code'];

        if (host == null || code == null) {
          throw Exception('Missing required invite link parameters.');
        }

        unawaited(_handleDeepLinkJoin(host: host, code: code));
      } catch (e) {
        _showError('Invalid invite link: $e');
      }
    } else {
      _showPasscodePromptAndJoin(input);
    }
  }

  void _showPasscodePromptAndJoin(String hostName) {
    final passcodeController = TextEditingController();
    bool obscureText = true;
    String? dialogErrorText;
    
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text('Join $hostName\'s Lobby'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This lobby is secure. Please enter the passcode to decrypt the signaling handshake.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passcodeController,
                obscureText: obscureText,
                decoration: InputDecoration(
                  labelText: 'Lobby Passcode',
                  errorText: dialogErrorText,
                  border: const OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.outline,
                      width: 1.0,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2.0,
                    ),
                  ),
                  labelStyle: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscureText ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setDialogState(() {
                        obscureText = !obscureText;
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final passcode = passcodeController.text.trim();
                if (passcode.isEmpty) {
                  setDialogState(() {
                    dialogErrorText = 'Passcode cannot be empty.';
                  });
                  return;
                }
                Navigator.pop(context);
                _lobbyPasscode = passcode;
                _executeUsernameJoin(hostName, passcode);
              },
              child: const Text('Join'),
            ),
          ],
        ),
      ),
    );
  }

  void _executeUsernameJoin(String hostName, String passcode) {
    if (_isLoading) return;
    final settings = ref.read(watchPartySettingsProvider);
    final database = ref.read(watchPartyDatabaseProvider);

    _activeDatabase = database;
    _isHosting = false;
    _isLoading = true;
    _statusMessage = 'Checking for lobby...';
    setState(() {});

    _joinerService?.removeListener(_onJoinerUpdate);
    _joinerService?.dispose();

    _joinerService = WatchPartyJoinerService(settings, database);
    _joinerService!.addListener(_onJoinerUpdate);
    unawaited(_joinerService!.startJoining(
      hostName,
      settings.watchPartyUsername,
      passcode,
    ));
  }

  void _cancelConnection() {
    if (_isHosting) {
      if (_creatorService != null) {
        unawaited(_creatorService!.cancelHosting());
      }
    } else {
      _joinerService?.cancelJoining();
    }
    setState(() {
      _isLoading = false;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    _cancelConnection();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: const Text('WatchParty Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _copyInviteLink() {
    final settings = ref.read(watchPartySettingsProvider);
    final hostName = _activeHostName ?? 'Host';
    final passcode = _creatorService?.roomPasscode ?? '';

    final jsonStr = jsonEncode({
      'db': settings.watchPartyProjectId.trim(),
      'key': settings.watchPartyAnonKey.trim(),
      'turn_user': settings.watchPartyTurnUsername.trim(),
      'turn_pass': settings.watchPartyTurnPassword.trim(),
    });
    
    final encryptedCode = WatchPartyCrypto.encrypt(jsonStr, passcode, hostName);
    final inviteUrl = '${WatchPartyConfig.redirectUrl}?host=${Uri.encodeComponent(hostName)}&code=${Uri.encodeComponent(encryptedCode)}';

    unawaited(Clipboard.setData(ClipboardData(text: inviteUrl)));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite link copied to clipboard!')),
    );
  }

  List<String> _getLogs() {
    if (_isHosting) {
      return _creatorService?.diagnosticLogs ?? [];
    }
    return _joinerService?.diagnosticLogs ?? [];
  }

  bool _isLobbyReady() {
    return _isHosting && (_creatorService?.lobbyReady ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final activeSession = ref.watch(activeWatchPartyProvider);
    if (activeSession != null) {
      return WatchPartyChatScreen(
        session: activeSession,
        onJoinMediaStream: widget.onJoinMediaStream,
      );
    }

    final settings = ref.watch(watchPartySettingsProvider);
    final isDbConfigured = settings.watchPartyProjectId.isNotEmpty && 
                           settings.watchPartyAnonKey.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch Party'),
        centerTitle: false,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_isLoading) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _statusMessage,
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          if (_isLobbyReady()) ...[
                            const SizedBox(height: 16),
                            Center(
                              child: Column(
                                children: [
                                  const Text(
                                    'Room Passcode:',
                                    style: TextStyle(fontSize: 12, color: Colors.grey),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _creatorService?.roomPasscode ?? '',
                                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          letterSpacing: 2,
                                          color: Theme.of(context).colorScheme.primary,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isHosting) ...[
                    ElevatedButton.icon(
                      onPressed: _isLobbyReady() ? _copyInviteLink : null,
                      icon: _isLobbyReady()
                          ? const Icon(Icons.copy_rounded)
                          : const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                      label: Text(_isLobbyReady() ? 'Copy Invite Link' : 'Preparing Link...'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: _isLobbyReady()
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                        foregroundColor: _isLobbyReady()
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : null,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  ElevatedButton(
                    onPressed: _cancelConnection,
                    child: const Text('Cancel'),
                  ),
                ] else ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'WatchParty Username',
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.person_outline_rounded,
                                    color: Theme.of(context).colorScheme.primary,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    settings.watchPartyUsername.isEmpty ? 'Not Set' : settings.watchPartyUsername,
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                ],
                              ),
                              OutlinedButton.icon(
                                onPressed: () => showWatchPartyUsernameDialog(context, ref),
                                style: OutlinedButton.styleFrom(
                                  shape: const StadiumBorder(),
                                  side: BorderSide(color: Theme.of(context).colorScheme.primary),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                ),
                                icon: const Icon(Icons.edit_rounded, size: 16),
                                label: const Text('Change'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  if (!isDbConfigured) ...[
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: Theme.of(context).colorScheme.onErrorContainer,
                              size: 32,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Supabase Keys Unconfigured',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.onErrorContainer,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Hosting is disabled. You can still join a friend\'s party by pasting their link below.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onErrorContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Host a Watch Party',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Create a room to stream videos in sync with one friend.',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: isDbConfigured ? _startHost : null,
                            icon: const Icon(Icons.connected_tv_rounded),
                            label: Text(
                              settings.watchPartyUsername.isNotEmpty
                                  ? 'Start Hosting as ${settings.watchPartyUsername}'
                                  : 'Start Hosting',
                            ),
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Join a Watch Party',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Type your friend\'s username (if on same DB) or paste their invite link.',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _joinController,
                            decoration: const InputDecoration(
                              labelText: 'Host Username or Invite Link',
                              border: OutlineInputBorder(),
                              hintText: 'e.g. Alice or skystream://join...',
                            ),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _handleTextJoin,
                            icon: const Icon(Icons.people_rounded),
                            label: Text(
                              settings.watchPartyUsername.isNotEmpty
                                  ? 'Join Party as ${settings.watchPartyUsername}'
                                  : 'Join Party',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                              minimumSize: const Size.fromHeight(48),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
