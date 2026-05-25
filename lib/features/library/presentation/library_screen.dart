import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../core/providers/device_info_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'widgets/bookmarks_tab.dart';
import 'widgets/downloads_tab.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _pageController = PageController();

    // Sync PageView -> TabBar
    _pageController.addListener(() {
      if (!_tabController.indexIsChanging) {
        // Only update TabBar if swipe is happening (not a direct tab tap)
        final page = _pageController.page?.round() ?? 0;
        if (_tabController.index != page) {
          _tabController.animateTo(page);
        }
      }
    });

    // Sync TabBar -> PageView
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        _pageController.animateToPage(
          _tabController.index,
          duration: const Duration(milliseconds: 300),
          curve: Curves.ease,
        );
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    final isWidescreen = isTv || context.isTabletOrLarger;

    if (isWidescreen) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            // Inline header matching other widescreen screens
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                height: LayoutConstants.dashboardHeaderHeight,
                padding: const EdgeInsets.symmetric(
                  horizontal: LayoutConstants.dashboardContentPadding,
                ),
                child: Row(
                  children: [
                    Text(
                      AppLocalizations.of(context)!.library,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    // Tab chips
                    _buildTabChips(context),
                  ],
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (index) {
                  _tabController.animateTo(index);
                },
                physics: const BouncingScrollPhysics(),
                children: const [DownloadsTab(), BookmarksTab()],
              ),
            ),
          ],
        ),
      );
    }

    // Mobile layout: existing AppBar with TabBar
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.library),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              text: AppLocalizations.of(context)!.downloads,
              icon: const Icon(Icons.download_for_offline_rounded),
            ),
            Tab(
              text: AppLocalizations.of(context)!.bookmarks,
              icon: const Icon(Icons.bookmark_rounded),
            ),
          ],
        ),
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          _tabController.animateTo(index);
        },
        physics: const BouncingScrollPhysics(),
        children: const [DownloadsTab(), BookmarksTab()],
      ),
    );
  }

  Widget _buildTabChips(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tabChip(
              label: l10n.downloads,
              icon: Icons.download_for_offline_rounded,
              selected: _tabController.index == 0,
              onTap: () => _tabController.animateTo(0),
              theme: theme,
            ),
            const SizedBox(width: 8),
            _tabChip(
              label: l10n.bookmarks,
              icon: Icons.bookmark_rounded,
              selected: _tabController.index == 1,
              onTap: () => _tabController.animateTo(1),
              theme: theme,
            ),
          ],
        );
      },
    );
  }

  Widget _tabChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
          borderRadius: BorderRadius.circular(LayoutConstants.radiusPill),
          border: selected
              ? Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.3),
                )
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
