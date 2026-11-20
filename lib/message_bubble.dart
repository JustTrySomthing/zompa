import 'package:flutter/material.dart';

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
    final dark = colors.brightness == Brightness.dark;
    final background = outgoing
        ? (dark ? const Color(0xff154957) : const Color(0xffd7f1fb))
        : colors.surfaceContainerHighest;
    final foreground = outgoing
        ? (dark ? const Color(0xfff0fbff) : const Color(0xff092c3a))
        : colors.onSurface;
    final secondary = outgoing
        ? (dark ? const Color(0xffb8dce5) : const Color(0xff315665))
        : colors.onSurfaceVariant;

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
              onSurface: foreground,
              onSurfaceVariant: secondary,
              // Outlined controls use this border over the bubble.
              outline: secondary,
            ),
            iconTheme: theme.iconTheme.copyWith(color: secondary),
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
