import 'package:flutter/material.dart';
import '../../config/watchparty_settings.dart';

enum WatchPartyPlayChoice {
  watchTogether,
  skip,
}

class WatchPartyPlayResult {
  final WatchPartyPlayChoice choice;
  final bool waitForMembers;
  final bool allowMemberControl;

  const WatchPartyPlayResult({
    required this.choice,
    required this.waitForMembers,
    this.allowMemberControl = false,
  });
}

class WatchPartyPlayPromptDialog extends StatefulWidget {
  final WatchPartySettings settings;

  const WatchPartyPlayPromptDialog({
    super.key,
    required this.settings,
  });

  static Future<WatchPartyPlayResult?> show(
    BuildContext context, {
    required WatchPartySettings settings,
  }) {
    return showDialog<WatchPartyPlayResult>(
      context: context,
      barrierDismissible: true,
      builder: (context) => WatchPartyPlayPromptDialog(settings: settings),
    );
  }

  @override
  State<WatchPartyPlayPromptDialog> createState() => _WatchPartyPlayPromptDialogState();
}

class _WatchPartyPlayPromptDialogState extends State<WatchPartyPlayPromptDialog> {
  late bool _waitForMembers;
  late bool _allowMemberControl;

  @override
  void initState() {
    super.initState();
    _waitForMembers = widget.settings.waitForMembersDefault;
    _allowMemberControl = widget.settings.allowMemberControlDefault;
  }

  void _onToggleWaitForMembers(bool? value) {
    if (value == null) return;
    setState(() {
      _waitForMembers = value;
    });
    // Persist memory-based preference asynchronously
    widget.settings.update(waitForMembersDefault: value);
  }

  void _onToggleAllowMemberControl(bool? value) {
    if (value == null) return;
    setState(() {
      _allowMemberControl = value;
    });
    widget.settings.update(allowMemberControlDefault: value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: const Row(
        children: [
          Icon(Icons.groups_rounded, color: Colors.deepPurpleAccent),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'WatchParty Active',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Would you like to watch this video with your WatchParty room, or watch alone?',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: () => _onToggleWaitForMembers(!_waitForMembers),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              child: Row(
                children: [
                  Checkbox(
                    value: _waitForMembers,
                    onChanged: _onToggleWaitForMembers,
                    activeColor: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'Wait for members before starting',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => _onToggleAllowMemberControl(!_allowMemberControl),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
              child: Row(
                children: [
                  Checkbox(
                    value: _allowMemberControl,
                    onChanged: _onToggleAllowMemberControl,
                    activeColor: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      'Allow members to control playback',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(
              context,
              const WatchPartyPlayResult(
                choice: WatchPartyPlayChoice.skip,
                waitForMembers: false,
                allowMemberControl: false,
              ),
            );
          },
          child: const Text('Skip (Watch Alone)', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton.icon(
          onPressed: () {
            Navigator.pop(
              context,
              WatchPartyPlayResult(
                choice: WatchPartyPlayChoice.watchTogether,
                waitForMembers: _waitForMembers,
                allowMemberControl: _allowMemberControl,
              ),
            );
          },
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Watch Together'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
          ),
        ),
      ],
    );
  }
}
