import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'github_distribution.dart';
import 'game_audio.dart';

class LoveGameView extends StatefulWidget {
  LoveGameView.official({
    super.key,
    required GameRelease game,
    this.mode = 'solo',
    this.match,
    this.onMove,
  }) : reference = game.playerReference;

  LoveGameView.imported({super.key, required String id})
    : reference = {'id': id},
      mode = 'solo',
      match = null,
      onMove = null;

  final Map<String, Object> reference;
  final String mode;
  final String? match;
  final ValueChanged<int>? onMove;

  @override
  State<LoveGameView> createState() => _LoveGameViewState();
}

class _LoveGameViewState extends State<LoveGameView>
    with WidgetsBindingObserver {
  MethodChannel? _channel;
  String _audio = '100:100:100';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings =
        GameAudioScope.of(context)?.playerSettings ?? '100:100:100';
    if (_audio == settings) return;
    _audio = settings;
    _send('audio', settings);
  }

  @override
  void didUpdateWidget(LoveGameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.match != oldWidget.match) _syncMatch();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _send('pause', state != AppLifecycleState.resumed);
  }

  void _syncMatch() {
    if (widget.match case final match?) _send('match', match);
  }

  void _send(String method, Object argument) {
    final channel = _channel;
    if (channel != null)
      unawaited(
        channel
            .invokeMethod<void>(method, argument)
            .onError<PlatformException>((_, _) {})
            .onError<MissingPluginException>((_, _) {}),
      );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const Center(
        child: Text('This LÖVE player is available on Android.'),
      );
    }
    return AndroidView(
      viewType: 'io.zompado.love',
      creationParams: {
        ...widget.reference,
        'mode': widget.mode,
        'audio': _audio,
      },
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: {
        Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
      },
      onPlatformViewCreated: (id) {
        if (!mounted) return;
        final channel = MethodChannel('io.zompado.love/$id');
        _channel = channel;
        channel.setMethodCallHandler((call) async {
          if (mounted && call.method == 'move' && call.arguments is int) {
            widget.onMove?.call(call.arguments as int);
          }
        });
        _syncMatch();
        _send('audio', _audio);
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        if (lifecycle != null) didChangeAppLifecycleState(lifecycle);
      },
    );
  }
}
