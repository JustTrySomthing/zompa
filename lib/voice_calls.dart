import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chatmail.dart';
import 'voice_sdp.dart';

enum VoicePhase { incoming, starting, ringing, connecting, connected }

class _Call {
  _Call(
    this.token,
    this.chat,
    this.name,
    this.phase, {
    this.message,
    this.offer,
    this.ringSeconds = 118,
  });

  final int token, chat;
  final String name;
  VoicePhase phase;
  int? message;
  final String? offer;
  final int ringSeconds;
  bool muted = false, speaker = false;
}

class VoiceCalls extends ChangeNotifier {
  VoiceCalls(this._chatmail, this._host) {
    _events = _chatmail.calls.listen((event) => unawaited(_event(event)));
  }

  final Chatmail _chatmail;
  final MethodChannel _host;
  late final StreamSubscription<Json> _events;
  final _ended = <int>{};
  Timer? _timeout;
  _Call? _active;
  int _nextToken = 0;
  bool _disposed = false;
  String? error;

  bool get busy => _active != null;
  bool get audioActive =>
      _active?.phase == VoicePhase.connecting ||
      _active?.phase == VoicePhase.connected;

  Future<void> dial(int chat, String name) async {
    if (busy || _disposed) return;
    final call = _Call(++_nextToken, chat, name, VoicePhase.starting);
    _set(call);
    await _start(call);
  }

  Future<void> accept() async {
    final call = _active;
    if (call == null || call.phase != VoicePhase.incoming) return;
    _phase(call, VoicePhase.starting);
    await _start(call);
  }

  Future<void> _start(_Call call) async {
    try {
      final permission = await _host.invokeMethod<bool>('requestMicrophone');
      if (_active != call) return;
      if (permission != true) {
        _end(call, message: 'Allow microphone access to use voice calls.');
        return;
      }
      final ice = await _chatmail.iceServers();
      if (_active != call) return;
      if (call.message case final id? when call.offer != null) {
        if (!await _chatmail.callIsRinging(id)) {
          _end(call, signal: false, message: 'This call has ended.');
          return;
        }
      }
      if (_active != call) return;
      final sdp = await _host
          .invokeMethod<String>('voiceStart', {
            'token': call.token,
            'ice': ice,
            'offer': call.offer,
          })
          .timeout(const Duration(seconds: 25));
      if (_active != call) return;
      if (!validVoiceSdp(sdp)) throw const FormatException();
      if (call.offer != null) {
        if (!await _chatmail.callIsRinging(call.message!)) {
          _end(call, signal: false, message: 'This call has ended.');
          return;
        }
        if (_active != call) return;
        if (call.phase != VoicePhase.connected) {
          _phase(call, VoicePhase.connecting);
        }
        await _chatmail.acceptCall(call.message!, sdp!);
      } else {
        final message = await _chatmail.placeCall(call.chat, sdp!);
        if (_active != call) {
          unawaited(_signalEnd(message));
          return;
        }
        call.message = message;
        _phase(call, VoicePhase.ringing);
      }
    } on PlatformException catch (issue) {
      _end(call, message: issue.message ?? 'Couldn’t start the voice call.');
    } catch (_) {
      _end(call, message: 'Couldn’t start the voice call.');
    }
  }

  Future<void> _event(Json event) async {
    final id = event['msg_id'];
    final chat = event['chat_id'];
    if (_disposed || id is! int || chat is! int) return;
    final call = _active;
    switch (event['kind']) {
      case 'IncomingCall':
        if (event['has_video'] == true) return;
        await _incoming(chat, id);
      case 'OutgoingCallAccepted':
        if (call == null ||
            call.message != id ||
            call.chat != chat ||
            call.phase != VoicePhase.ringing)
          return;
        final answer = event['accept_call_info'];
        if (!validVoiceSdp(answer)) {
          _end(call, message: 'This call used an unsupported audio format.');
          return;
        }
        _phase(call, VoicePhase.connecting);
        try {
          await _host.invokeMethod<void>('voiceAnswer', {
            'token': call.token,
            'answer': answer,
          });
        } catch (_) {
          _end(call, message: 'Couldn’t connect voice audio.');
        }
      case 'CallEnded':
      case 'IncomingCallAccepted' when event['from_this_device'] != true:
        if (_ended.length >= 64) _ended.remove(_ended.first);
        _ended.add(id);
        if (call != null && call.message == id && call.chat == chat) {
          _end(call, signal: false);
        }
    }
  }

  Future<void> restoreIncoming(int chat, int id) =>
      _incoming(chat, id, fromNotification: true);

  Future<void> _incoming(
    int chat,
    int id, {
    bool fromNotification = false,
  }) async {
    try {
      if (fromNotification && !await _chatmail.restore()) return;
      final offer = await _chatmail.incomingVoiceCall(
        chat,
        id,
        fromNotification: fromNotification,
      );
      if (_disposed ||
          offer == null ||
          !validVoiceSdp(offer.offer) ||
          _ended.contains(id) ||
          _active?.message == id)
        return;
      if (busy) {
        unawaited(_signalEnd(id));
        return;
      }
      _set(
        _Call(
          ++_nextToken,
          chat,
          offer.name,
          VoicePhase.incoming,
          message: id,
          offer: offer.offer,
          ringSeconds: offer.secondsLeft,
        ),
      );
      if (!fromNotification) {
        unawaited(
          _native('showIncomingCall', {
            'chat': chat,
            'message': id,
            'secondsLeft': offer.secondsLeft,
            'foreground':
                WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed,
          }),
        );
      }
    } catch (_) {
      // A mismatched, unverified, or expired call cannot ring.
    }
  }

  void mediaEvent(Object? data) {
    final call = _active;
    if (call == null || data is! Map || data['token'] != call.token) return;
    switch (data['status']) {
      case 'connected':
        _phase(call, VoicePhase.connected);
      case 'failed':
        _end(
          call,
          message: data['message'] as String? ?? 'The voice call stopped.',
        );
    }
  }

  void hangUp() {
    final call = _active;
    if (call != null) _end(call);
  }

  void _end(_Call call, {bool signal = true, String? message}) {
    if (_active != call || _disposed) return;
    _timeout?.cancel();
    _active = null;
    error = message;
    unawaited(_native('voiceEnd', {'token': call.token}));
    if (call.message case final id?) {
      unawaited(_native('dismissIncomingCall', {'message': id}));
      if (signal) unawaited(_signalEnd(id));
    }
    notifyListeners();
  }

  Future<void> _signalEnd(int message) async {
    try {
      await _chatmail.endCall(message);
    } catch (_) {
      // The call still ends locally if the relay is unavailable.
    }
  }

  Future<void> _native(String name, Map<String, Object?> args) async {
    try {
      await _host.invokeMethod<void>(name, args);
    } catch (_) {
      // Local controls and state remain available if Android posts no alert.
    }
  }

  void _set(_Call call) {
    _active = call;
    error = null;
    _phase(call, call.phase);
  }

  void _phase(_Call call, VoicePhase phase) {
    if (_active != call) return;
    call.phase = phase;
    _timeout?.cancel();
    if (phase != VoicePhase.connected) {
      _timeout = Timer(
        Duration(
          seconds: switch (phase) {
            VoicePhase.starting => 55,
            VoicePhase.connecting => 30,
            VoicePhase.incoming => call.ringSeconds,
            _ => 118,
          },
        ),
        () => _end(call, message: 'The call timed out.'),
      );
    }
    if (call.message case final id? when phase != VoicePhase.incoming) {
      unawaited(_native('dismissIncomingCall', {'message': id}));
    }
    notifyListeners();
  }

  Future<void> changeAudio({required bool speaker}) async {
    final call = _active;
    if (call == null) return;
    final method = speaker ? 'voiceSpeaker' : 'voiceMute';
    final value = !(speaker ? call.speaker : call.muted);
    try {
      final changed = await _host.invokeMethod<bool>(method, {
        'token': call.token,
        'value': value,
      });
      if (_active != call || changed != true) return;
      if (speaker) {
        call.speaker = value;
      } else {
        call.muted = value;
      }
      notifyListeners();
    } catch (_) {
      // Android may remove an audio device during a call.
    }
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    hangUp();
    _disposed = true;
    _events.cancel();
    _timeout?.cancel();
    super.dispose();
  }
}

class VoiceScope extends InheritedNotifier<VoiceCalls> {
  const VoiceScope({super.key, required VoiceCalls calls, required super.child})
    : super(notifier: calls);

  static VoiceCalls? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VoiceScope>()?.notifier;
}

class VoiceBar extends StatelessWidget {
  const VoiceBar({super.key});

  @override
  Widget build(BuildContext context) {
    final calls = VoiceScope.of(context);
    final call = calls?._active;
    final error = calls?.error;
    if (call == null && error == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    call == null
                        ? error!
                        : switch (call.phase) {
                            VoicePhase.incoming =>
                              'Incoming call from ${call.name}',
                            VoicePhase.starting => 'Preparing voice audio…',
                            VoicePhase.ringing => 'Calling ${call.name}…',
                            VoicePhase.connecting =>
                              'Connecting to ${call.name}…',
                            VoicePhase.connected =>
                              'Voice call with ${call.name}',
                          },
                  ),
                ),
              ),
              if (call == null)
                _VoiceButton(
                  tooltip: 'Dismiss call message',
                  onPressed: calls!.clearError,
                  icon: const Icon(Icons.close),
                )
              else ...[
                if (call.phase == VoicePhase.incoming)
                  _VoiceButton(
                    tooltip: 'Answer',
                    onPressed: calls!.accept,
                    icon: const Icon(Icons.call),
                  ),
                if (call.phase == VoicePhase.connected) ...[
                  _VoiceButton(
                    tooltip: call.muted
                        ? 'Unmute microphone'
                        : 'Mute microphone',
                    onPressed: () => calls!.changeAudio(speaker: false),
                    icon: Icon(call.muted ? Icons.mic_off : Icons.mic),
                  ),
                  _VoiceButton(
                    tooltip: call.speaker
                        ? 'Turn off speaker'
                        : 'Turn on speaker',
                    onPressed: () => calls!.changeAudio(speaker: true),
                    icon: Icon(call.speaker ? Icons.volume_up : Icons.hearing),
                  ),
                ],
                _VoiceButton(
                  tooltip: call.phase == VoicePhase.incoming
                      ? 'Decline'
                      : 'End call',
                  onPressed: calls!.hangUp,
                  color: colors.error,
                  icon: const Icon(Icons.call_end),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _VoiceButton extends StatelessWidget {
  const _VoiceButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final String tooltip;
  final Icon icon;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: tooltip,
    child: IconButton(onPressed: onPressed, color: color, icon: icon),
  );
}
