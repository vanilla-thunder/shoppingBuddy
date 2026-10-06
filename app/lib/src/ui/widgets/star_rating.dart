import 'package:flutter/material.dart';

/// Five tappable stars. Tapping the current rating clears it (calls [onChanged] with null).
class StarRating extends StatelessWidget {
  const StarRating({super.key, required this.rating, this.onChanged, this.size = 28});

  final int? rating;
  final ValueChanged<int?>? onChanged;
  final double size;

  static const filledColor = Color(0xFFE8A317);

  @override
  Widget build(BuildContext context) {
    final off = Theme.of(context).colorScheme.outlineVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var n = 1; n <= 5; n++)
          Semantics(
            button: onChanged != null,
            selected: rating == n,
            label: '$n of 5 stars',
            child: InkResponse(
              onTap: onChanged == null ? null : () => onChanged!(n == rating ? null : n),
              radius: size * 0.7,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  rating != null && n <= rating! ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: size,
                  color: rating != null && n <= rating! ? filledColor : off,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
