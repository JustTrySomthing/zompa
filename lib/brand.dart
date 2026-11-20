import 'package:flutter/material.dart';

abstract final class ZompadoBrand {
  static const ink = Color(0xff091a20);
  static const wordmarkBlue = Color(0xff5cb3db);
  static const bubbleBlue = Color(0xff5ecffe);
  static const white = Color(0xfffefefe);
  static const darkPanel = Color(0xff122a35);
  static const lightPanel = Color(0xffeff6f9);
  static const markAsset = 'docs/brand/bubble.png';
  static const wordmarkAsset = 'docs/brand/wordmark.png';

  static ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: wordmarkBlue,
          brightness: brightness,
        ).copyWith(
          primary: dark ? bubbleBlue : const Color(0xff075473),
          onPrimary: dark ? ink : white,
          secondary: dark ? wordmarkBlue : const Color(0xff124c64),
          onSecondary: dark ? ink : white,
          secondaryContainer: bubbleBlue,
          onSecondaryContainer: ink,
          surface: dark ? ink : white,
          onSurface: dark ? white : ink,
          surfaceContainer: dark ? darkPanel : lightPanel,
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
          backgroundColor: bubbleBlue,
          foregroundColor: ink,
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
