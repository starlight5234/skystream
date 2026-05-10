import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class AppSidebar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bgColor = Theme.of(context).appBarTheme.backgroundColor;

    final destinations = [
      (Icons.home_outlined, Icons.home, l10n.home),
      (Icons.search, Icons.search, l10n.search),
      (Icons.explore_outlined, Icons.explore, l10n.explore),
      (Icons.library_books_outlined, Icons.library_books, l10n.library),
      (Icons.settings_outlined, Icons.settings, l10n.settings),
    ];

    return Material(
      color: bgColor,
      elevation: 8,
      child: SizedBox(
        width: 80,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(destinations.length, (i) {
            final (outlinedIcon, filledIcon, label) = destinations[i];
            final isSelected = currentIndex == i;
            return _SidebarItem(
              focusNode: focusNodes[i],
              icon: isSelected ? filledIcon : outlinedIcon,
              label: label,
              isSelected: isSelected,
              onTap: () => onItemTapped(i),
            );
          }),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final FocusNode focusNode;
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.focusNode,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    final isActive = widget.isSelected || _isFocused;

    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            widget.onTap();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: widget.isSelected
                ? primary.withValues(alpha: 0.15)
                : Colors.transparent,
            border: _isFocused ? Border.all(color: primary, width: 2) : null,
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: primary.withValues(alpha: 0.4),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                color: isActive ? primary : onSurfaceVariant,
                size: 24,
              ),
              const SizedBox(height: 4),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 10,
                  color: isActive ? primary : onSurfaceVariant,
                  fontWeight:
                      widget.isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
