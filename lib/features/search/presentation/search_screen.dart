import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../core/providers/device_info_provider.dart';
import 'search_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'widgets/search_result_section.dart';
import 'widgets/search_header_bar.dart';
import '../../../shared/widgets/cards_wrapper.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Restore any previously committed query into the text field.
    _controller.text = ref.read(searchQueryProvider);
    _focusNode.addListener(_onFocusChanged);
    _focusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        final suggestionState = ref.read(searchSuggestionControllerProvider);
        final typedLongEnough = suggestionState.query.trim().length >= 2;
        final hasSuggestionContent =
            suggestionState.isLoading || suggestionState.suggestions.isNotEmpty;

        if (typedLongEnough && hasSuggestionContent) {
          FocusManager.instance.primaryFocus?.focusInDirection(
            TraversalDirection.down,
          );
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    };
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submitSearch(String val) {
    final trimmed = val.trim();
    _controller.value = TextEditingValue(
      text: trimmed,
      selection: TextSelection.collapsed(offset: trimmed.length),
    );
    ref.read(searchSuggestionControllerProvider.notifier).clear();
    ref.read(searchQueryProvider.notifier).set(trimmed);
    // Dismiss keyboard after submitting, just like YouTube / browser.
    _focusNode.unfocus();
  }

  void _fillSuggestion(String suggestion) {
    _controller.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
    ref
        .read(searchSuggestionControllerProvider.notifier)
        .onQueryChanged(suggestion);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    final isWidescreen = isTv || context.isTabletOrLarger;

    if (isWidescreen) {
      return Scaffold(
        extendBodyBehindAppBar: false,
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SearchHeaderBar(
                textController: _controller,
                searchFocusNode: _focusNode,
                onSubmitted: _submitSearch,
                onChanged: (val) {
                  ref
                      .read(searchSuggestionControllerProvider.notifier)
                      .onQueryChanged(val);
                },
              ),
            ),
            Expanded(child: _buildBody(context)),
          ],
        ),
      );
    }

    // Mobile layout: existing AppBar
    return _buildMobileLayout(context);
  }

  Widget _buildMobileLayout(BuildContext context) {
    final searchResultsAsync = ref.watch(searchResultsProvider);
    final filter = ref.watch(searchFilterProvider);
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isLive = filter == SearchFilter.live;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
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
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.3,
                  ),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  isLive ? '📺' : '🍿',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
          ),
        ],
        title: GestureDetector(
          onTap: () => _focusNode.requestFocus(),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 42,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
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
                      _controller.clear();
                      ref
                          .read(searchSuggestionControllerProvider.notifier)
                          .clear();
                      ref.read(searchQueryProvider.notifier).set('');
                    },
                  );
                }

                return TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: false,
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface,
                  ),
                  textAlignVertical: TextAlignVertical.center,
                  textInputAction: TextInputAction.search,
                  onChanged: (val) {
                    ref
                        .read(searchSuggestionControllerProvider.notifier)
                        .onQueryChanged(val);
                  },
                  onSubmitted: _submitSearch,
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
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
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final searchResultsAsync = ref.watch(searchResultsProvider);
    final suggestionState = ref.watch(searchSuggestionControllerProvider);
    final l10n = AppLocalizations.of(context)!;
    final typedLongEnough = suggestionState.query.trim().length >= 2;
    final hasSuggestionContent =
        suggestionState.isLoading || suggestionState.suggestions.isNotEmpty;
    final showSuggestions = typedLongEnough && hasSuggestionContent;

    return showSuggestions
        ? _buildSuggestionsView(context, suggestionState)
        : searchResultsAsync.when(
            data: (state) {
              final allResults = state.results
                  .expand((e) => e.results)
                  .toList();

              if (allResults.isEmpty && !state.isLoading) {
                return _buildEmptyState(context);
              } else if (allResults.isEmpty && state.isLoading) {
                return const Center(child: CircularProgressIndicator());
              }

              // RepaintBoundary isolates list repaints from the rest of the
              // screen (app bar, background) so each incremental result update
              // only repaints the list — not the entire scaffold.
              return RepaintBoundary(
                child: ListView.builder(
                  padding: const EdgeInsets.only(
                    bottom: LayoutConstants.spacingMd,
                  ),
                  itemCount: state.results.length,
                  itemBuilder: (context, index) {
                    final pResult = state.results[index];
                    return SearchResultSection(
                      key: ValueKey(pResult.providerId),
                      providerName: pResult.providerName,
                      providerId: pResult.providerId,
                      results: pResult.results,
                    );
                  },
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, stack) =>
                Center(child: Text(l10n.errorPrefix(err.toString()))),
          );
  }

  Widget _buildSuggestionsView(
    BuildContext context,
    SearchSuggestionState suggestionState,
  ) {
    if (suggestionState.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (suggestionState.suggestions.isEmpty) {
      return Center(
        child: Text(
          'No results found',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: suggestionState.suggestions.length,
      itemBuilder: (context, index) {
        final suggestion = suggestionState.suggestions[index];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Material(
            type: MaterialType.transparency,
            child: ListTile(
              onTap: () => _submitSearch(suggestion),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              leading: const Icon(Icons.search_rounded),
              title: Text(suggestion),
              trailing: IconButton(
                tooltip: 'Fill query',
                icon: const Icon(Icons.north_west_rounded),
                focusNode: FocusNode(
                  canRequestFocus: false,
                ), // Prevent stealing focus from D-pad
                onPressed: () => _fillSuggestion(suggestion),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = ref.watch(searchQueryProvider);
    if (query.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.movie_filter_rounded,
              size: 64,
              color: Theme.of(context).dividerColor,
            ),
            const SizedBox(height: LayoutConstants.spacingMd),
            Text(
              l10n.searchFavoriteContent,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.pressSearchOrEnter,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return Center(child: Text(l10n.noResultsFound));
  }
}
