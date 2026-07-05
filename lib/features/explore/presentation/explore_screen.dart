import 'package:carousel_slider/carousel_slider.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/widgets/cards_wrapper.dart';
import '../data/explore_tmdb_provider.dart';
import 'view_all_screen.dart';
import 'widgets/explore_carousel.dart';
import 'widgets/explore_header_bar.dart';
import 'widgets/media_horizontal_list.dart';
import 'widgets/unified_filter_dialog.dart';
import '../data/explore_filter_provider.dart';
import 'delegates/explore_search_delegate.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../shared/widgets/shimmer_placeholder.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'dart:async';

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen>
    with AutomaticKeepAliveClientMixin {
  late ScrollController _scrollController;
  final ValueNotifier<bool> _isScrolledNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<double> _appBarOpacityNotifier = ValueNotifier<double>(0);
  final FocusNode _firstActionFocusNode = FocusNode();

  /// Carousel controller exposed by ExploreCarousel via [onControllerReady].
  CarouselSliderController? _carouselController;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
  }

  bool _isWidescreenForScroll() {
    final profile = ref.read(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    return isTv ||
        profile?.isLargeScreen == true ||
        context.isTabletOrLarger;
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // On widescreen there is no mobile AppBar, skip calculations
    if (_isWidescreenForScroll()) return;

    final offset = _scrollController.offset * 0.8;
    final opacity = (offset / 300).clamp(0.0, 1.0);
    if (opacity != _appBarOpacityNotifier.value) {
      _appBarOpacityNotifier.value = opacity;
    }
    final isScrolled = _scrollController.offset > 200;
    if (isScrolled != _isScrolledNotifier.value) {
      _isScrolledNotifier.value = isScrolled;
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _isScrolledNotifier.dispose();
    _appBarOpacityNotifier.dispose();
    _firstActionFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin

    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    // Use profile?.isLargeScreen so this matches AppScaffold's sidebar
    // decision even when the ExploreScreen's context width is narrowed
    // by the sidebar (e.g. iPad portrait).
    final isWidescreen = isTv || profile?.isLargeScreen == true || context.isTabletOrLarger;

    if (isWidescreen) {
      return Scaffold(
        extendBodyBehindAppBar: false,
        backgroundColor: Colors.transparent,
        body: _buildWidescreenBody(context),
      );
    }

    // Mobile layout: existing AppBar
    return ValueListenableBuilder<bool>(
      valueListenable: _isScrolledNotifier,
      builder: (context, isScrolled, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final overlayStyle = isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark;

        return Scaffold(
          backgroundColor: Theme.of(
            context,
          ).scaffoldBackgroundColor, // Base background
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            systemOverlayStyle: overlayStyle,
            forceMaterialTransparency: true,
            backgroundColor: Colors.transparent,
            elevation: 0,
            flexibleSpace: ValueListenableBuilder<double>(
              valueListenable: _appBarOpacityNotifier,
              // See home_screen.dart for why we fade via color alpha rather
              // than Opacity — same saveLayer-per-frame issue.
              builder: (context, opacity, child) {
                return Container(
                  color: Theme.of(
                    context,
                  ).scaffoldBackgroundColor.withValues(alpha: opacity),
                );
              },
            ),
            title: Text(
              AppLocalizations.of(context)!.explore,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 24,
              ),
            ),
            centerTitle: false,
            actions: [
              Padding(
                padding: const EdgeInsets.only(
                  right: LayoutConstants.spacingMd,
                ),
                child: CardsWrapper(
                  onTap: () {
                    unawaited(
                      showDialog<void>(
                        context: context,
                        builder: (context) => const UnifiedFilterDialog(),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(50),
                  child: Consumer(
                    builder: (context, ref, _) {
                      final filters = ref.watch(
                        exploreFilterProvider,
                      ); // Updated
                      // Language exclusion: Only highlight for content filters
                      final hasActiveFilter =
                          filters.selectedGenre != null ||
                          filters.selectedYear != null ||
                          filters.minRating != null;

                      return CircleAvatar(
                        backgroundColor: hasActiveFilter
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.1),
                        radius: 18,
                        child: Icon(
                          Icons.tune,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 18,
                        ),
                      );
                    },
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.only(
                  right: LayoutConstants.spacingMd,
                ),
                child: CardsWrapper(
                  onTap: () {
                    unawaited(
                      showSearch<void>(
                        context: context,
                        delegate: ExploreSearchDelegate(),
                        useRootNavigator: false,
                        maintainState: true,
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(50),
                  child: CircleAvatar(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.1),
                    radius: 18,
                    child: Icon(
                      Icons.search,
                      color: Theme.of(context).colorScheme.onSurface,
                      size: 18,
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: _buildScrollView(context),
        );
      },
    );
  }

  Widget _buildWidescreenBody(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ExploreHeaderBar(
            searchFocusNode: _firstActionFocusNode,
            onPrevious: _carouselController != null
                ? () => _carouselController!.previousPage()
                : null,
            onNext: _carouselController != null
                ? () => _carouselController!.nextPage()
                : null,
          ),
        ),
        Expanded(
          child: _buildScrollView(context),
        ),
      ],
    );
  }

  Widget _buildScrollView(BuildContext context) {
    final heroMoviesAsync = ref.watch(exploreHeroMovieProvider);
    final isNone = heroMoviesAsync.maybeWhen(
      data: (list) => list.isEmpty,
      error: (_, __) => true,
      orElse: () => false,
    );
    final topPadding = isNone ? (MediaQuery.paddingOf(context).top + kToolbarHeight) : 0.0;

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        if (topPadding > 0)
          SliverToBoxAdapter(child: SizedBox(height: topPadding)),
        ..._buildContentSlivers(context).map((sliver) {
          return SliverSafeArea(
            top: false,
            bottom: false,
            left: true,
            right: true,
            sliver: sliver,
          );
        }),
        const SliverSafeArea(
          top: false,
          left: true,
          right: true,
          sliver: SliverToBoxAdapter(child: SizedBox(height: 100)),
        ),
      ],
    );
  }



  List<Widget> _buildContentSlivers(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return [
      SliverToBoxAdapter(
        child: Consumer(
          builder: (context, ref, _) {
            final heroMoviesAsync = ref.watch(exploreHeroMovieProvider);
            return switch (heroMoviesAsync) {
              AsyncData(:final value) =>
                value.isEmpty
                    ? const SizedBox.shrink()
                    : ExploreCarousel(
                        movies: value,
                        scrollController: _scrollController,
                        onNavigateUp: () =>
                            _firstActionFocusNode.requestFocus(),
                        onControllerReady: (c) =>
                            setState(() => _carouselController = c),
                      ),
              AsyncLoading() => _buildCarouselShimmer(context),
              AsyncError() => Container(
                height: 500,
                margin: const EdgeInsets.only(
                  bottom: LayoutConstants.spacingLg,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: 48,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        AppLocalizations.of(context)!.couldNotLoadTrending,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () =>
                            ref.invalidate(exploreHeroMovieProvider),
                        icon: const Icon(Icons.refresh),
                        label: Text(AppLocalizations.of(context)!.retry),
                      ),
                    ],
                  ),
                ),
              ),
            };
          },
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(popularMoviesProvider),
          l10n.popularMovies,
          ViewAllCategory.popularMovies,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(popularTVProvider),
          l10n.popularTVShows,
          ViewAllCategory.popularTV,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(nowPlayingMoviesProvider),
          l10n.newMovies,
          ViewAllCategory.nowPlayingMovies,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(onTheAirTVProvider),
          l10n.newTVShows,
          ViewAllCategory.onTheAirTV,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(topRatedMoviesProvider),
          l10n.featuredMovies,
          ViewAllCategory.topRatedMovies,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(topRatedTVProvider),
          l10n.featuredTVShows,
          ViewAllCategory.topRatedTV,
        ),
      ),

      SliverToBoxAdapter(
        child: _buildSection(
          context,
          ref.watch(airingTodayTVProvider),
          l10n.lastVideosTVShows,
          ViewAllCategory.airingTodayTV,
        ),
      ),
    ];
  }

  Widget _buildSection(
    BuildContext context,
    AsyncValue<List<MultimediaItem>> asyncValue,
    String title,
    ViewAllCategory category,
  ) {
    return switch (asyncValue) {
      AsyncData(:final value) =>
        value.isEmpty
            ? const SizedBox.shrink()
            : MediaHorizontalList(
                title: title,
                mediaList: value,
                category: category,
                heroTagPrefix: 'explore',
              ),
      AsyncLoading() => _buildListShimmer(context),
      AsyncError() => const SizedBox.shrink(),
    };
  }

  Widget _buildCarouselShimmer(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final heroHeight = size.height * 0.60;
    final isDesktop =
        size.width > LayoutConstants.exploreCarouselDesktopBreakpoint;
    
    if (isDesktop) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LayoutConstants.dashboardContentPadding,
          vertical: LayoutConstants.spacingSm,
        ),
        child: SizedBox(
          height: heroHeight,
          width: double.infinity,
          child: ShimmerPlaceholder(borderRadius: 18),
        ),
      );
    } else {
      return SizedBox(
        height: heroHeight,
        width: double.infinity,
        child: ShimmerPlaceholder.rectangular(
          width: double.infinity,
          height: heroHeight,
          borderRadius: 0,
        ),
      );
    }
  }

  Widget _buildListShimmer(BuildContext context) {
    final isDesktop = context.isDesktop;
    final cardWidth = isDesktop ? 200.0 : 130.0;
    final imageHeight = cardWidth / (2 / 3);
    final listHeight = imageHeight + 40.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title Placeholder
        Padding(
          padding: EdgeInsets.fromLTRB(
            isDesktop
                ? LayoutConstants.dashboardContentPadding
                : LayoutConstants.spacingMd,
            LayoutConstants.spacingLg,
            isDesktop
                ? LayoutConstants.dashboardContentPadding
                : LayoutConstants.spacingMd,
            LayoutConstants.spacingSm,
          ),
            child: ShimmerPlaceholder.rectangular(
              width: 150,
              height: 24,
              borderRadius: 4,
            ),
          ),
          const SizedBox(height: LayoutConstants.spacingMd),
          // List Placeholder
          SizedBox(
            height: listHeight,
            child: ListView.separated(
              padding: EdgeInsets.symmetric(
                horizontal: isDesktop
                    ? LayoutConstants.dashboardContentPadding
                    : LayoutConstants.spacingMd,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: 10,
              separatorBuilder: (_, _) => SizedBox(
                width: isDesktop
                    ? LayoutConstants.spacingLg
                    : LayoutConstants.spacingSm,
              ),
              itemBuilder: (context, index) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShimmerPlaceholder.rectangular(
                      width: cardWidth,
                      height: imageHeight,
                      borderRadius: 12,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      );
  }
}
