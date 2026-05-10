import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/utils/responsive_breakpoints.dart';
import 'package:skystream/shared/widgets/custom_bottom_nav.dart';
import 'package:skystream/shared/widgets/app_sidebar.dart';

import 'package:skystream/l10n/generated/app_localizations.dart';
import '../../features/settings/presentation/general_settings_provider.dart';

class AppScaffold extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;
  const AppScaffold({super.key, required this.navigationShell});

  @override
  ConsumerState<AppScaffold> createState() => _AppScaffoldState();
}

class _AppScaffoldState extends ConsumerState<AppScaffold> {
  // Owned here so the content-area LEFT key handler can focus them directly,
  // crossing the Branch Navigator's FocusScope boundary.
  static const _sidebarItemCount = 5;
  late final List<FocusNode> _sidebarNodes = List.generate(
    _sidebarItemCount,
    (i) => FocusNode(debugLabel: 'sidebar_$i'),
  );

  @override
  void dispose() {
    for (final n in _sidebarNodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _onItemTapped(int index, BuildContext context) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  int _getRouteIndex(String route) {
    switch (route) {
      case '/home':
        return 0;
      case '/search':
        return 1;
      case '/explore':
        return 2;
      case '/library':
        return 3;
      case '/settings':
        return 4;
      default:
        return 0;
    }
  }

  // Intercepts D-pad LEFT before DpadNavigator's CallbackShortcuts can consume
  // it, because this Focus sits above the Branch Navigator in the focus tree.
  // From inside the Branch scope, focusInDirection(left) can't reach the
  // sidebar (different FocusScope), so we focus the sidebar item explicitly.
  KeyEventResult _onContentKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      final idx = widget.navigationShell.currentIndex;
      _sidebarNodes[idx].requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final deviceProfileAsync = ref.watch(deviceProfileProvider);
    final defaultHome = ref.watch(
      generalSettingsProvider.select((s) => s.defaultHomeScreen),
    );
    final defaultIndex = _getRouteIndex(defaultHome);
    final isAtDefaultHome = widget.navigationShell.currentIndex == defaultIndex;

    return deviceProfileAsync.when(
      data: (profile) {
        if (profile.isTv || context.isTabletOrLarger) {
          return PopScope(
            canPop: isAtDefaultHome,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) {
                widget.navigationShell.goBranch(defaultIndex);
              }
            },
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Row(
                children: [
                  // Sidebar in its own traversal group so UP/DOWN stays inside it.
                  FocusTraversalGroup(
                    policy: WidgetOrderTraversalPolicy(),
                    child: AppSidebar(
                      currentIndex: widget.navigationShell.currentIndex,
                      onItemTapped: (int index) => _onItemTapped(index, context),
                      focusNodes: _sidebarNodes,
                    ),
                  ),
                  // Content in its own traversal group.
                  // The inner Focus wrapper intercepts LEFT before it can
                  // escape to CallbackShortcuts, then explicitly focuses the
                  // correct sidebar item — bypassing the FocusScope boundary.
                  Expanded(
                    child: FocusTraversalGroup(
                      policy: WidgetOrderTraversalPolicy(),
                      child: Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        onKeyEvent: _onContentKeyEvent,
                        child: widget.navigationShell,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // Mobile uses Bottom Navigation
        return PopScope(
          canPop: isAtDefaultHome,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              widget.navigationShell.goBranch(defaultIndex);
            }
          },
          child: Scaffold(
            body: widget.navigationShell,
            bottomNavigationBar: CustomBottomNavBar(
              currentIndex: widget.navigationShell.currentIndex,
              onTap: (index) => _onItemTapped(index, context),
            ),
          ),
        );
      },
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (err, stack) => Scaffold(
          body: Center(
              child: Text(
                  AppLocalizations.of(context)!.errorPrefix(err.toString())))),
    );
  }
}
