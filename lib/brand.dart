import 'package:flutter/material.dart';

enum ThemeColor {
  blue(
    'Blue',
    Color(0xff1978bd),
    light: (
      accent: Color(0xff00507a),
      surface: Color(0xffe5edf1),
      panel: Color(0xffd3e1e8),
      bubble: Color(0xffb8d6e6),
      raised: Color(0xffc3d4de),
    ),
    dark: (
      accent: Color(0xff5ecffe),
      surface: Color(0xff091a20),
      panel: Color(0xff122a35),
      bubble: Color(0xff154957),
      raised: Color(0xff263d46),
    ),
  ),
  purple(
    'Purple',
    Color(0xff8c58cf),
    light: (
      accent: Color(0xff55328b),
      surface: Color(0xffeae6f0),
      panel: Color(0xffded6e9),
      bubble: Color(0xffd7c8ed),
      raised: Color(0xffd2c8e0),
    ),
    dark: (
      accent: Color(0xffcdb3ff),
      surface: Color(0xff191525),
      panel: Color(0xff241d34),
      bubble: Color(0xff40305e),
      raised: Color(0xff342b46),
    ),
  ),
  red(
    'Red',
    Color(0xffdb4b62),
    light: (
      accent: Color(0xff972839),
      surface: Color(0xfff4e7e7),
      panel: Color(0xffedd9db),
      bubble: Color(0xfff0c7cd),
      raised: Color(0xffe3cbd0),
    ),
    dark: (
      accent: Color(0xffff9fab),
      surface: Color(0xff211518),
      panel: Color(0xff301d23),
      bubble: Color(0xff502932),
      raised: Color(0xff412a31),
    ),
  ),
  orange(
    'Orange',
    Color(0xffe57830),
    light: (
      accent: Color(0xff8d3a08),
      surface: Color(0xfff1e9e1),
      panel: Color(0xffebdad0),
      bubble: Color(0xfff2d0b6),
      raised: Color(0xffe2d1c6),
    ),
    dark: (
      accent: Color(0xffffb181),
      surface: Color(0xff221911),
      panel: Color(0xff30231a),
      bubble: Color(0xff542f1c),
      raised: Color(0xff453023),
    ),
  ),
  yellow(
    'Yellow',
    Color(0xffe8bd3c),
    light: (
      accent: Color(0xff685007),
      surface: Color(0xfff2eddf),
      panel: Color(0xffe9dfc3),
      bubble: Color(0xffeedba3),
      raised: Color(0xffe0d6b9),
    ),
    dark: (
      accent: Color(0xfff3d477),
      surface: Color(0xff211c11),
      panel: Color(0xff302817),
      bubble: Color(0xff483b1e),
      raised: Color(0xff40351f),
    ),
  ),
  green(
    'Green',
    Color(0xff3ba66c),
    light: (
      accent: Color(0xff175c3b),
      surface: Color(0xffe7eee8),
      panel: Color(0xffd6e4d9),
      bubble: Color(0xffc5e0cc),
      raised: Color(0xffc7dbce),
    ),
    dark: (
      accent: Color(0xff91e2b1),
      surface: Color(0xff111e18),
      panel: Color(0xff1a2c23),
      bubble: Color(0xff234c36),
      raised: Color(0xff2b3e33),
    ),
  );

  const ThemeColor(
    this.label,
    this.swatch, {
    required _ThemePalette light,
    required _ThemePalette dark,
  }) : _light = light,
       _dark = dark;

  final String label;
  final Color swatch;
  final _ThemePalette _light, _dark;

  static ThemeColor fromPreference(Object? value) =>
      values.where((color) => color.name == value).firstOrNull ?? blue;

  _ThemePalette _palette(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;
}

typedef _ThemePalette = ({
  Color accent,
  Color surface,
  Color panel,
  Color bubble,
  Color raised,
});

abstract final class ZompadoBrand {
  static const ink = Color(0xff091a20);
  static const wordmarkBlue = Color(0xff5cb3db);
  static const bubbleBlue = Color(0xff5ecffe);
  static const white = Color(0xfffefefe);
  static const darkPanel = Color(0xff122a35);
  static const markAsset = 'docs/brand/bubble.png';
  static const wordmarkAsset = 'docs/brand/wordmark.png';

  static ThemeData theme(
    Brightness brightness, {
    ThemeColor color = ThemeColor.blue,
  }) {
    final dark = brightness == Brightness.dark;
    final palette = color._palette(brightness);
    final text = dark ? white : ink;
    final accentText = dark ? palette.surface : white;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: brightness,
        ).copyWith(
          primary: palette.accent,
          onPrimary: accentText,
          primaryContainer: palette.bubble,
          onPrimaryContainer: text,
          secondary: palette.accent,
          onSecondary: accentText,
          secondaryContainer: palette.accent,
          onSecondaryContainer: accentText,
          surface: palette.surface,
          onSurface: text,
          onSurfaceVariant: Color.alphaBlend(
            text.withValues(alpha: .8),
            palette.surface,
          ),
          surfaceContainerLow: Color.lerp(palette.surface, palette.panel, .55),
          surfaceContainer: palette.panel,
          surfaceContainerHigh: Color.lerp(palette.panel, palette.raised, .53),
          surfaceContainerHighest: palette.raised,
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
