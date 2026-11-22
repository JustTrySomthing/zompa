import 'package:flutter/material.dart';

import 'brand.dart';

const double minMessageTextSize = 12;
const double defaultMessageTextSize = 14;
const double maxMessageTextSize = 24;

double messageTextSizeFrom(Object? value) => value is num && value.isFinite
    ? value.clamp(minMessageTextSize, maxMessageTextSize).toDouble()
    : defaultMessageTextSize;

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.outgoing,
    required this.builder,
  });

  final bool outgoing;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = outgoing
        ? colors.surfaceContainerHighest
        : colors.secondaryContainer;
    final foreground = ZompaBrand.inkOnAccent(background);
    final detail = Color.alphaBlend(
      foreground.withValues(alpha: .78),
      background,
    );
    final secondary = ZompaBrand.readableAccent(
      detail,
      background,
      foreground,
    );
    final action = ZompaBrand.readableAccent(
      colors.primary,
      background,
      foreground,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Theme(
          data: theme.copyWith(
            colorScheme: colors.copyWith(
              primary: action,
              onSurface: foreground,
              onSurfaceVariant: secondary,
              // Outlined controls use this border over the bubble.
              outline: secondary,
            ),
            iconTheme: theme.iconTheme.copyWith(color: secondary),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(foregroundColor: action),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(foregroundColor: action),
            ),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: foreground),
            child: Builder(builder: builder),
          ),
        ),
      ),
    );
  }
}

class MessageBody extends StatelessWidget {
  const MessageBody(
    this.text, {
    super.key,
    required this.size,
    this.bold = false,
  });

  final String text;
  final double size;
  final bool bold;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: size,
      fontWeight: bold ? FontWeight.w600 : null,
      height: 1.4,
    ),
  );
}
