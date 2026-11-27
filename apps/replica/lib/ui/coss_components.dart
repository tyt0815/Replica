import 'package:flutter/material.dart';

class CossCard extends StatelessWidget {
  const CossCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF111114) : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outline),
        boxShadow: isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ],
      ),
      child: child,
    );
  }
}

class CossSegmentedTabs<T> extends StatelessWidget {
  const CossSegmentedTabs({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.activeColor = const Color(0xFFFF0035),
  });

  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          GestureDetector(
            onTap: () => onSelected(items[i].$1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected == items[i].$1
                    ? activeColor
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected == items[i].$1
                      ? activeColor
                      : theme.colorScheme.outline,
                  width: 1.2,
                ),
              ),
              child: Text(
                items[i].$2,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontSize: 15.5,
                  height: 1.0,
                  fontWeight: selected == items[i].$1
                      ? FontWeight.w700
                      : FontWeight.w600,
                  color: selected == items[i].$1
                      ? Colors.white
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class CossIconButton extends StatelessWidget {
  const CossIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.outlined = false,
    this.circular = false,
    this.iconColor,
    this.size = 36,
    this.iconSize = 20,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool outlined;
  final bool circular;
  final Color? iconColor;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final side = outlined
        ? BorderSide(color: theme.colorScheme.outline)
        : BorderSide.none;
    final ShapeBorder shape = circular
        ? CircleBorder(side: side)
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: side,
          );
    final button = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: outlined
            ? (isDark ? const Color(0xFF141418) : const Color(0xFFFFFFFF))
            : Colors.transparent,
        shape: shape,
        child: InkWell(
          customBorder: circular ? const CircleBorder() : null,
          borderRadius: circular ? null : BorderRadius.circular(9),
          onTap: onPressed,
          child: Icon(
            icon,
            size: iconSize,
            color: onPressed == null
                ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
                : (iconColor ?? theme.colorScheme.onSurface),
          ),
        ),
      ),
    );
    if (tooltip == null) {
      return button;
    }
    return Tooltip(message: tooltip!, child: button);
  }
}

class CossBadge extends StatelessWidget {
  const CossBadge({super.key, required this.label, this.dotColor});

  final String label;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
