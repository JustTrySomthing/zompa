import 'package:flutter/material.dart';

// Swatch names, values, and order follow Relay Lab’s Appearance settings.
enum ThemeColor {
  crimson('Crimson', Color(0xffc83146)),
  tangerine('Tangerine', Color(0xffd57d21)),
  gold('Gold', Color(0xffd8b828)),
  emerald('Emerald', Color(0xff187950)),
  royalBlue('Royal Blue', Color(0xff245aa4)),
  classicViolet('Violet', Color(0xff5c3895)),
  hotPink('Hot Pink', Color(0xffff4194)),
  neonOrange('Neon Orange', Color(0xffff793d)),
  electricYellow('Electric Yellow', Color(0xfffff13b)),
  neonGreen('Neon Green', Color(0xff23df3a)),
  electricCyan('Electric Cyan', Color(0xff26d8e9)),
  electricPurple('Electric Purple', Color(0xffaa71ff)),
  rose('Rose', Color(0xffd3749d)),
  apricot('Apricot', Color(0xffd99569)),
  softGold('Soft Gold', Color(0xffcaa95c)),
  seaGreen('Sea Green', Color(0xff64a58d)),
  steelBlue('Steel Blue', Color(0xff709ebd)),
  lavender('Lavender', Color(0xff9d86c6));

  const ThemeColor(this.label, this.swatch);
  final String label;
  final Color swatch;

  static ThemeColor fromPreference(Object? value) => switch (value) {
    'blue' => royalBlue,
    'purple' => classicViolet,
    'red' => crimson,
    'orange' => tangerine,
    'yellow' => gold,
    'green' => emerald,
    _ => values.where((color) => color.name == value).firstOrNull ?? royalBlue,
  };
}

abstract final class ZompaBrand {
  static const ink = Color(0xff091a20);
  static const wordmarkBlue = Color(0xff5cb3db);
  static const bubbleBlue = Color(0xff5ecffe);
  static const white = Color(0xfffefefe);
  static const darkPanel = Color(0xff122a35);
  static const markAsset = 'docs/brand/bubble.png';
  static const wordmarkAsset = 'docs/brand/wordmark.png';

  static double contrastRatio(Color first, Color second) {
    final a = first.computeLuminance() + .05;
    final b = second.computeLuminance() + .05;
    return a >= b ? a / b : b / a;
  }

  static Color inkOnAccent(Color background) =>
      contrastRatio(background, Colors.black) >=
          contrastRatio(background, Colors.white)
      ? Colors.black
      : Colors.white;

  static Color readableAccent(Color accent, Color background, Color fallback) {
    if (contrastRatio(accent, background) >= 4.5) return accent;
    return contrastRatio(fallback, background) >= 4.5
        ? fallback
        : inkOnAccent(background);
  }

  static Color actionInk(ColorScheme colors) =>
      [
        colors.surface,
        colors.surfaceContainer,
        colors.surfaceContainerHighest,
      ].every((surface) => contrastRatio(colors.primary, surface) >= 4.5)
      ? colors.primary
      : colors.onSurface;

  static ThemeData theme(
    Brightness brightness, {
    ThemeColor color = ThemeColor.royalBlue,
  }) {
    final dark = brightness == Brightness.dark;
    final accent = color.swatch;
    final accentInk = inkOnAccent(accent);
    final background = dark ? const Color(0xff171717) : const Color(0xfff8f8f8);
    final panel = dark ? const Color(0xff242424) : const Color(0xfff0f0f0);
    final variant = dark ? const Color(0xff303337) : const Color(0xffe4e6e9);
    final text = dark ? const Color(0xfff2f2f2) : const Color(0xff222222);
    final muted = dark ? const Color(0xffb9b9b9) : const Color(0xff505050);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          onPrimary: accentInk,
          primaryContainer: accent,
          onPrimaryContainer: accentInk,
          secondary: accent,
          onSecondary: accentInk,
          secondaryContainer: accent,
          onSecondaryContainer: accentInk,
          surface: background,
          surfaceDim: background,
          surfaceBright: panel,
          surfaceContainerLowest: background,
          surfaceContainerLow: panel,
          surfaceContainer: panel,
          surfaceContainerHigh: variant,
          surfaceContainerHighest: variant,
          onSurface: text,
          onSurfaceVariant: muted,
          outline: dark ? const Color(0xff757575) : const Color(0xff686868),
          surfaceTint: Colors.transparent,
        );
    final action = actionInk(scheme);

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
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: action),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: action),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.error)
                ? scheme.error
                : states.contains(WidgetState.focused)
                ? action
                : muted,
          ),
        ),
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
                    color: ZompaBrand.ink,
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
                                    color: ZompaBrand.bubbleBlue.withValues(
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
                                  ZompaBrand.markAsset,
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
                                ZompaBrand.wordmarkAsset,
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
