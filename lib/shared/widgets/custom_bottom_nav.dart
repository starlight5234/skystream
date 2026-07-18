import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class CustomBottomNavBar extends ConsumerWidget {
  final int currentIndex;
  final void Function(int) onTap;

  const CustomBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {

    return Container(
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface),
      child: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: onTap,
        backgroundColor: Colors.transparent,
        indicatorColor: Theme.of(
          context,
        ).colorScheme.primary.withValues(alpha: 0.15),
        elevation: 0,
        labelBehavior:
            NavigationDestinationLabelBehavior.alwaysHide, // Cleaner look
        height: 65,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: Icon(
              Icons.home,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: AppLocalizations.of(context)!.home,
          ),
          NavigationDestination(
            icon: const Icon(Icons.search_outlined),
            selectedIcon: Icon(
              Icons.search,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: AppLocalizations.of(context)!.search,
          ),
          NavigationDestination(
            icon: const Icon(Icons.explore_outlined),
            selectedIcon: Icon(
              Icons.explore,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: AppLocalizations.of(context)!.explore,
          ),
          NavigationDestination(
            icon: const Icon(Icons.video_library_outlined),
            selectedIcon: Icon(
              Icons.video_library,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: AppLocalizations.of(context)!.library,
          ),
          NavigationDestination(
            icon: const Icon(Icons.people_alt_outlined),
            selectedIcon: Icon(
              Icons.people_alt,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: 'Watch Party',
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: Icon(
              Icons.settings,
              color: Theme.of(context).colorScheme.primary,
            ),
            label: AppLocalizations.of(context)!.settings,
          ),
        ],
      ),
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
