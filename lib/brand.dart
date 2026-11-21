import 'dart:math' as math;

import 'package:flutter/material.dart';

abstract final class ZompadoBrand {
  static const ink = Color(0xff091a20);
  static const wordmarkBlue = Color(0xff5cb3db);
  static const bubbleBlue = Color(0xff5ecffe);
  static const white = Color(0xfffefefe);
  static const darkPanel = Color(0xff122a35);
  static const lightPanel = Color(0xffd3e1e8);
  static const defaultHue = 198.0;
  static const markAsset = 'docs/brand/bubble.png';
  static const wordmarkAsset = 'docs/brand/wordmark.png';

  static double hueFrom(Object? value) => value is num && value.isFinite
      ? value.clamp(0, 360).toDouble()
      : defaultHue;

  static ThemeData theme(Brightness brightness, {double hue = defaultHue}) {
    final dark = brightness == Brightness.dark;
    Color tint(Color color) {
      if (hue == defaultHue) return color;
      final hsl = HSLColor.fromColor(color);
      return hsl.withHue((hsl.hue + hue - defaultHue) % 360).toColor();
    }

    final surface = tint(dark ? ink : const Color(0xffe5edf1));
    final text = dark ? white : tint(ink);
    final sentBubble = tint(
      dark ? const Color(0xff154957) : const Color(0xffb8d6e6),
    );
    final high = tint(dark ? const Color(0xff263d46) : const Color(0xffc3d4de));
    final mutedText = Color.alphaBlend(text.withValues(alpha: .8), surface);
    final accentText = dark ? surface : white;
    final backgrounds = [surface, sentBubble, high, accentText];
    final luminances = backgrounds.map((color) => color.computeLuminance());
    final against = luminances.reduce(dark ? math.max : math.min);

    Color readableAccent(Color base) {
      var hsl = HSLColor.fromColor(tint(base));
      var accent = hsl.toColor();
      bool readable() {
        final luminance = accent.computeLuminance();
        return dark
            ? (luminance + .05) >= 4.5 * (against + .05)
            : (against + .05) >= 4.5 * (luminance + .05);
      }

      while (!readable()) {
        hsl = hsl.withLightness(
          (hsl.lightness + (dark ? .025 : -.025)).clamp(0, 1),
        );
        accent = hsl.toColor();
      }
      return accent;
    }

    final accent = readableAccent(dark ? bubbleBlue : const Color(0xff00507a));
    final scheme =
        ColorScheme.fromSeed(
          seedColor: tint(wordmarkBlue),
          brightness: brightness,
        ).copyWith(
          primary: accent,
          onPrimary: accentText,
          primaryContainer: sentBubble,
          onPrimaryContainer: text,
          secondary: readableAccent(
            dark ? wordmarkBlue : const Color(0xff124c64),
          ),
          onSecondary: accentText,
          secondaryContainer: accent,
          onSecondaryContainer: accentText,
          surface: surface,
          onSurface: text,
          onSurfaceVariant: mutedText,
          surfaceContainerLow: tint(
            dark ? const Color(0xff102329) : const Color(0xffdfe9ee),
          ),
          surfaceContainer: tint(dark ? darkPanel : lightPanel),
          surfaceContainerHigh: tint(
            dark ? const Color(0xff1c3541) : const Color(0xffcadbe4),
          ),
          surfaceContainerHighest: high,
        );

    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Noto Sans',
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
        ),
      ),
    );
  }
}

class BrandLaunch extends StatefulWidget {
  const BrandLaunch({super.key, required this.child});

  final Widget child;

  @override
  State<BrandLaunch> createState() => _BrandLaunchState();
}

class _BrandLaunchState extends State<BrandLaunch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _motion =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1500),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _finish();
        });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_finished) _motion.forward();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
      _finished = true;
    }
  }

  void _finish() {
    if (!_finished && mounted) setState(() => _finished = true);
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeSemantics(
        excluding: !_finished,
        child: IgnorePointer(ignoring: !_finished, child: widget.child),
      ),
      if (!_finished)
        ExcludeSemantics(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _motion,
              builder: (context, child) {
                final t = _motion.value;
                final settle = const Interval(
                  0,
                  .44,
                  curve: Curves.easeOutCubic,
                ).transform(t);
                final lift = const Interval(
                  .19,
                  .50,
                  curve: Curves.easeOutCubic,
                ).transform(t);
                final reveal = const Interval(
                  .24,
                  .55,
                  curve: Curves.easeOutCubic,
                ).transform(t);
                final ring = const Interval(
                  .07,
                  .62,
                  curve: Curves.easeOutCubic,
                ).transform(t);
                final fade = const Interval(
                  .75,
                  1,
                  curve: Curves.easeInOutCubic,
                ).transform(t);

                return Opacity(
                  opacity: 1 - fade,
                  child: ColoredBox(
                    color: ZompadoBrand.ink,
                    child: Center(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (ring > 0 && ring < 1)
                            Transform.scale(
                              scale: .65 + ring * 1.15,
                              child: Container(
                                width: 105,
                                height: 105,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: ZompadoBrand.bubbleBlue.withValues(
                                      alpha: .36 * (1 - ring),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Transform.translate(
                            offset: Offset(0, -23 * lift),
                            child: Transform.rotate(
                              angle: -.12 * (1 - settle),
                              child: Transform.scale(
                                scale: .85 + .15 * settle + .035 * fade,
                                child: Image.asset(
                                  ZompadoBrand.markAsset,
                                  width: 110,
                                  height: 110,
                                ),
                              ),
                            ),
                          ),
                          Transform.translate(
                            offset: Offset(0, 77 - 10 * reveal),
                            child: Opacity(
                              opacity: reveal,
                              child: Image.asset(
                                ZompadoBrand.wordmarkAsset,
                                width: 216,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
    ],
  );
}
