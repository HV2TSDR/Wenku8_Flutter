import 'package:flutter/material.dart';
import 'app_ui.dart';

/// Small, visible sets of choices share the app's glass button and hit area.
class GlassChoiceGroup<T> extends StatelessWidget {
  const GlassChoiceGroup({
    super.key,
    required this.name,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.leading,
    this.optionName,
    this.labelSize = 14,
    this.optionSize = 13,
    this.enabled = true,
  });
  final String name, label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final Widget Function(T)? leading;
  final String Function(T)? optionName;
  final double labelSize, optionSize;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: AppText(
          label,
          style: TextStyle(fontSize: labelSize, fontWeight: FontWeight.w600),
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final entry in options.entries)
            Semantics(
              selected: entry.key == value,
              inMutuallyExclusiveGroup: true,
              child: GlassTextButton(
                compact: true,
                selected: entry.key == value,
                key: ValueKey(
                  '$name-${optionName?.call(entry.key) ?? entry.key}',
                ),
                onPressed: enabled ? () => onChanged(entry.key) : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      leading!(entry.key),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: AppText(
                        entry.value,
                        style: TextStyle(
                          fontSize: optionSize,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ],
  );
}
