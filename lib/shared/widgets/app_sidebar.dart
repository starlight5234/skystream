import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dpad/dpad.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/core/utils/layout_constants.dart';
import 'package:skystream/core/utils/responsive_breakpoints.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import '../../features/watchparty/presentation/providers/watchparty_notification_provider.dart';

/// Number of destinations rendered by [AppSidebar]. Used by [AppScaffold] to
/// size its own FocusNode list so the two stay in sync — change this and the
/// destinations list together.
const int kSidebarDestinationCount = 6;

class AppSidebar extends ConsumerStatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onItemTapped;
  // FocusNodes owned by the parent scaffold so the content-area key handler
  // can focus them directly, crossing the Branch Navigator's FocusScope boundary.
  final List<FocusNode> focusNodes;

  const AppSidebar({
    super.key,
    required this.currentIndex,
    required this.onItemTapped,
    required this.focusNodes,
  });

  @override
  ConsumerState<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends ConsumerState<AppSidebar> {
  bool _isExpanded = true;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(settingsRepositoryProvider);
    final savedState = repo.getSidebarExpanded();
    if (savedState != null) {
      _isExpanded = savedState;
    } else {
      // Apply defaults based on platform
      final profile = ref.read(deviceProfileProvider).asData?.value;
      if (profile?.isTv == true || profile?.isTablet == true) {
        _isExpanded = false;
      } else {
        _isExpanded = true;
      }
    }
  }

  void _toggleSidebar() {
    final newState = !_isExpanded;
    setState(() {
      _isExpanded = newState;
    });
    unawaited(
      ref.read(settingsRepositoryProvider).setSidebarExpanded(newState),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final notificationState = ref.watch(watchPartyNotificationProvider);

    // Sidebar background: seamless with scaffold
    final bgColor = theme.scaffoldBackgroundColor;

    final destinations = [
      (Icons.home_outlined, Icons.home, l10n.home),
      (Icons.search, Icons.search, l10n.search),
      (Icons.explore_outlined, Icons.explore, l10n.explore),
      (Icons.video_library_outlined, Icons.video_library, l10n.library),
      (Icons.people_alt_outlined, Icons.people_alt, 'Watch Party'),
      (Icons.settings_outlined, Icons.settings, l10n.settings),
    ];
    assert(
      destinations.length == kSidebarDestinationCount,
      'kSidebarDestinationCount must match the destinations list length',
    );
    assert(
      widget.focusNodes.length == destinations.length,
      'Sidebar focusNodes count must match destinations count',
    );

    return Material(
      color: bgColor,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            width: _isExpanded
                ? LayoutConstants.sidebarWidthExpanded
                : LayoutConstants.sidebarWidthCompact,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isFullyExpanded = constraints.maxWidth > 160;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Hamburger and Branding
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        height: LayoutConstants.dashboardHeaderHeight,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: isFullyExpanded
                              ? MainAxisAlignment.start
                              : MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.menu),
                              onPressed: _toggleSidebar,
                              color: theme.colorScheme.onSurface,
                              splashRadius: 24,
                            ),
                            if (isFullyExpanded) ...[
                              Image.asset(
                                'assets/images/ic_launcher_foreground.png',
                              ),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: 'SkyStream',
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800,
                                          color: theme.colorScheme.onSurface,
                                          letterSpacing: -0.5,
                                        ),
                                      ),
                                      TextSpan(
                                        text: '.',
                                        style: TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    if (isFullyExpanded)
                      const SizedBox(height: LayoutConstants.spacingSm),

                    if (!isFullyExpanded)
                      Center(
                        child: Image.asset(
                          'assets/images/ic_launcher_foreground.png',
                        ),
                      ),

                    // Combined flat navigation list
                    ...List.generate(destinations.length, (i) {
                      final (outlinedIcon, filledIcon, label) = destinations[i];
                      final isSelected = widget.currentIndex == i;
                      final isWatchParty = (i == 4);
                      return _SidebarItem(
                        focusNode: widget.focusNodes[i],
                        icon: isSelected ? filledIcon : outlinedIcon,
                        label: label,
                        isSelected: isSelected,
                        isExpanded: isFullyExpanded,
                        autofocus: i == 0 && context.isTv,
                        onTap: () => widget.onItemTapped(i),
                        hasUnread: isWatchParty && notificationState.hasUnread,
                        messageCount: isWatchParty ? notificationState.messageCount : 0,
                      );
                    }),

                    const Spacer(),
                  ],
                );
              },
            ),
          ),
          Container(
            width: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.05),
                  theme.colorScheme.primary.withValues(alpha: 0.2),
                  theme.colorScheme.primary.withValues(alpha: 0.5),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final FocusNode focusNode;
  final IconData icon;
  final String label;
  final bool isSelected;
  final bool isExpanded;
  final VoidCallback onTap;
  final bool autofocus;
  final bool hasUnread;
  final int messageCount;

  const _SidebarItem({
    required this.focusNode,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.isExpanded,
    required this.onTap,
    this.autofocus = false,
    this.hasUnread = false,
    this.messageCount = 0,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final onSurfaceVariant = theme.colorScheme.onSurfaceVariant;
    final isActive = widget.isSelected || _isFocused;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 12),
      child: Focus(
        autofocus: widget.autofocus,
        focusNode: widget.focusNode,
        onFocusChange: (focused) => setState(() => _isFocused = focused),
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space) {
              widget.onTap();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final innerContent = GestureDetector(
              onTap: () {
                widget.focusNode.requestFocus();
                widget.onTap();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 12,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: widget.isSelected
                      ? primary.withValues(alpha: 0.1)
                      : Colors.transparent,
                ),
                child: Row(
                  mainAxisAlignment: widget.isExpanded
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    // Active pill indicator (only when expanded, or adjust if you want it collapsed too)
                    if (widget.isExpanded)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 4,
                        height: widget.isSelected ? 24 : 0,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: widget.isSelected
                              ? primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    _buildBadgeIcon(
                      context,
                      primary,
                      Icon(
                        widget.icon,
                        color: isActive ? primary : onSurfaceVariant,
                        size: widget.isExpanded ? 28 : 24,
                      ),
                    ),
                    if (widget.isExpanded) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.label,
                          style: TextStyle(
                            fontSize: 15,
                            color: isActive ? primary : onSurfaceVariant,
                            fontWeight: widget.isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );

            // Apply the dpad package's border effect instead of glow
            return FocusEffects.border(
              focusColor: primary,
              borderRadius: BorderRadius.circular(12),
            )(context, _isFocused, innerContent);
          },
        ),
      ),
    );
  }

  Widget _buildBadgeIcon(BuildContext context, Color primaryColor, Widget child) {
    if (!widget.hasUnread) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -4,
          top: -4,
          child: widget.messageCount > 1
              ? BlinkingBadgeDot(color: primaryColor)
              : Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: primaryColor,
                    shape: BoxShape.circle,
                  ),
                ),
        ),
      ],
    );
  }
}

class BlinkingBadgeDot extends StatefulWidget {
  final Color color;
  const BlinkingBadgeDot({super.key, required this.color});

  @override
  State<BlinkingBadgeDot> createState() => _BlinkingBadgeDotState();
}

class _BlinkingBadgeDotState extends State<BlinkingBadgeDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
