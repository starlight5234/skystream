import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/core/utils/layout_constants.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/cards_wrapper.dart';
import '../search_provider.dart';

/// A custom header bar for the search screen in widescreen/desktop layout.
///
/// Contains: an interactive search TextField and a filter popup, matching
/// the dashboard header bar style used by Home and Explore screens.
class SearchHeaderBar extends ConsumerStatefulWidget {
  final TextEditingController textController;
  final FocusNode searchFocusNode;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String> onChanged;

  const SearchHeaderBar({
    super.key,
    required this.textController,
    required this.searchFocusNode,
    required this.onSubmitted,
    required this.onChanged,
  });

  @override
  ConsumerState<SearchHeaderBar> createState() => _SearchHeaderBarState();
}

class _SearchHeaderBarState extends ConsumerState<SearchHeaderBar> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final filter = ref.watch(searchFilterProvider);
    final isLive = filter == SearchFilter.live;
    final searchResultsAsync = ref.watch(searchResultsProvider);

    return Container(
      height: LayoutConstants.dashboardHeaderHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.dashboardContentPadding,
      ),
      child: Row(
        children: [
          // Search TextField
          Expanded(
            child: SizedBox(
              height: 42,
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.textController,
                builder: (context, value, child) {
                  final isSearching = searchResultsAsync.maybeWhen(
                    data: (state) => state.isLoading,
                    loading: () => true,
                    orElse: () => false,
                  );

                  Widget? suffix;
                  if (isSearching) {
                    suffix = Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    );
                  } else if (value.text.isNotEmpty) {
                    suffix = IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        widget.textController.clear();
                        ref
                            .read(searchSuggestionControllerProvider.notifier)
                            .clear();
                        ref.read(searchQueryProvider.notifier).set('');
                      },
                    );
                  }

                  return TextField(
                    controller: widget.textController,
                    focusNode: widget.searchFocusNode,
                    autofocus: false,
                    style: TextStyle(
                      fontSize: 14,
                      color: theme.colorScheme.onSurface,
                    ),
                    textAlignVertical: TextAlignVertical.center,
                    textInputAction: TextInputAction.search,
                    onChanged: widget.onChanged,
                    onSubmitted: widget.onSubmitted,
                    decoration: InputDecoration(
                      hintText: l10n.searchHint,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          LayoutConstants.radiusPill,
                        ),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          LayoutConstants.radiusPill,
                        ),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          LayoutConstants.radiusPill,
                        ),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 42,
                      ),
                      suffixIcon: suffix,
                    ),
                  );
                },
              ),
            ),
          ),

          const SizedBox(width: 12),

          // Filter popup
          CardsWrapper(
            scaleFactor: 1.01,
            onTap: () {},
            borderRadius: BorderRadius.circular(50),
            child: PopupMenuButton<SearchFilter>(
              tooltip: 'Search scope',
              onSelected: (value) =>
                  ref.read(searchFilterProvider.notifier).set(value),
              offset: const Offset(0, 48),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: SearchFilter.content,
                  child: Row(
                    children: [
                      const Text('🍿', style: TextStyle(fontSize: 18)),
                      const SizedBox(width: 12),
                      const Expanded(child: Text('Non Livestreams')),
                      if (!isLive)
                        Icon(
                          Icons.check,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: SearchFilter.live,
                  child: Row(
                    children: [
                      const Text('📺', style: TextStyle(fontSize: 18)),
                      const SizedBox(width: 12),
                      const Expanded(child: Text('Livestreams')),
                      if (isLive)
                        Icon(
                          Icons.check,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                ),
              ],
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.3,
                  ),
                ),
                child: Text(
                  isLive ? '📺' : '🍿',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
