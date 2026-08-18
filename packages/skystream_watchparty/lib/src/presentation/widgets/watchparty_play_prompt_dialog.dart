import 'package:flutter/material.dart';

enum WatchPartyPlayChoice {
  shareSuggestion,
  watchAlone,
  cancel,
}

class WatchPartyPlayPromptDialog extends StatelessWidget {
  final String? title;

  const WatchPartyPlayPromptDialog({
    super.key,
    this.title,
  });

  static Future<WatchPartyPlayChoice?> show(
    BuildContext context, {
    String? title,
  }) {
    return showDialog<WatchPartyPlayChoice>(
      context: context,
      barrierDismissible: true,
      builder: (context) => WatchPartyPlayPromptDialog(title: title),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayTitle = title != null && title!.isNotEmpty ? '"$title"' : 'this video';

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
          Text(
            'You are in an active WatchParty. Would you like to share $displayTitle as a suggestion to the party, or watch it alone?',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, WatchPartyPlayChoice.cancel),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, WatchPartyPlayChoice.watchAlone),
          child: const Text('Watch Alone'),
        ),
        ElevatedButton.icon(
          onPressed: () => Navigator.pop(context, WatchPartyPlayChoice.shareSuggestion),
          icon: const Icon(Icons.share_rounded, size: 16),
          label: const Text('Share Suggestion'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
          ),
        ),
      ],
    );
  }
}
