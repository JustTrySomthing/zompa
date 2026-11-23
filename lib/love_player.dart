import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'github_distribution.dart';
import 'game_audio.dart';
import 'voice_calls.dart';

class LoveGameView extends StatefulWidget {
  LoveGameView.official({
    super.key,
    required GameRelease game,
    this.mode = 'solo',
    this.fresh = false,
    this.match,
    this.onMove,
    this.onTurn,
    this.paused = false,
  }) : reference = {
         ...game.playerReference,
         'localSaves': game.supportsLocalSaves,
       };

  LoveGameView.imported({super.key, required String id, this.paused = false})
    : reference = {'id': id},
      mode = 'solo',
      fresh = false,
      match = null,
      onMove = null,
      onTurn = null;

  final Map<String, Object> reference;
  final String mode;
  final bool fresh;
  final String? match;
  final ValueChanged<int>? onMove;
  final ValueChanged<String>? onTurn;
  final bool paused;

  @override
  State<LoveGameView> createState() => LoveGameViewState();
}

class LoveGameViewState extends State<LoveGameView>
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
    final callAudioActive = VoiceScope.of(context)?.audioActive ?? false;
    final settings =
        GameAudioScope.of(context)
            ?.playerSettings(callAudioActive: callAudioActive) ??
        '100:100:100';
    if (_audio == settings) return;
    _audio = settings;
    _send('audio', settings);
  }

  @override
  void didUpdateWidget(LoveGameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.match != oldWidget.match) _syncMatch();
    if (widget.paused != oldWidget.paused) {
      _send(
        'pause',
        widget.paused ||
            WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _send('pause', widget.paused || state != AppLifecycleState.resumed);
  }

  Future<String?> instructions() async {
    try {
      return await _channel?.invokeMethod<String>('instructions');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> leave({required bool quit}) async {
    await _channel?.invokeMethod<void>('leave', quit);
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
      viewType: 'io.zompa.love',
      creationParams: {
        ...widget.reference,
        'mode': widget.mode,
        'fresh': widget.fresh,
        'audio': _audio,
      },
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: {
        Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
      },
      onPlatformViewCreated: (id) {
        if (!mounted) return;
        final channel = MethodChannel('io.zompa.love/$id');
        _channel = channel;
        channel.setMethodCallHandler((call) async {
          if (mounted &&
              !widget.paused &&
              call.method == 'move' &&
              call.arguments is int) {
            widget.onMove?.call(call.arguments as int);
          }
          if (mounted &&
              !widget.paused &&
              call.method == 'turn' &&
              call.arguments is String) {
            widget.onTurn?.call(call.arguments as String);
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
