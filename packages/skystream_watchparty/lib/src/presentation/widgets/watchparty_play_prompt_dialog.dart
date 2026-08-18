import 'package:flutter/material.dart';

enum WatchPartyPlayChoice {
  shareSuggestion,
  watchAlone,
  cancel,
}

class WatchPartyPlayPromptDialog extends StatelessWidget {
  final String? title;
  final bool isShareable;

  const WatchPartyPlayPromptDialog({
    super.key,
    this.title,
    this.isShareable = true,
  });

  static Future<WatchPartyPlayChoice?> show(
    BuildContext context, {
    String? title,
    bool isShareable = true,
  }) {
    return showDialog<WatchPartyPlayChoice>(
      context: context,
      barrierDismissible: true,
      builder: (context) => WatchPartyPlayPromptDialog(
        title: title,
        isShareable: isShareable,
      ),
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
          if (!isShareable) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: Colors.orangeAccent),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Local or direct media cannot be shared to WatchParty.',
                      style: TextStyle(fontSize: 11, color: Colors.orangeAccent),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
          onPressed: isShareable
              ? () => Navigator.pop(context, WatchPartyPlayChoice.shareSuggestion)
              : null,
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
