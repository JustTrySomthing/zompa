import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import 'brand.dart';
import 'app_log.dart';
import 'chat_avatar.dart';
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
    this.incomingVideo = false,
  });

  final int token, chat;
  final String name;
  VoicePhase phase;
  int? message;
  final String? offer;
  final int ringSeconds;
  final bool incomingVideo;
  bool canVideo = false;
  bool camera = false;
  bool resumeLocalVideo = false;
  bool remoteCamera = false;
  bool selfPreview = true;
  bool voiceOnly = false;
  bool changingCamera = false;
  String? cameraError;
  Json? earlyAnswer;
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
  final _visibleGames = <Object>{};
  bool _callHidden = false;

  void setGameVisible(Object owner, bool visible) {
    if (_disposed) return;
    final wasInGame = _visibleGames.isNotEmpty;
    if (visible) {
      _visibleGames.add(owner);
    } else {
      _visibleGames.remove(owner);
    }
    if (_visibleGames.isEmpty) _callHidden = false;
    if (wasInGame != _visibleGames.isNotEmpty && busy) notifyListeners();
  }

  void showCall() {
    if (!_callHidden) return;
    _callHidden = false;
    notifyListeners();
  }

  void _hideCall() {
    if (_visibleGames.isEmpty || _active?.phase == VoicePhase.incoming) return;
    _callHidden = true;
    notifyListeners();
  }

  String? error;

  bool get busy => _active != null;
  bool get audioActive =>
      _active?.phase == VoicePhase.connecting ||
      _active?.phase == VoicePhase.connected;

  Future<void> openDialer(
    BuildContext context,
    int chat,
    String name, {
    String? photo,
  }) async {
    if (busy || _disposed) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final confirmed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _CallDialer(name: name, photo: photo),
      ),
    );
    if (confirmed == true && context.mounted) await dial(chat, name);
  }

  Future<void> dial(int chat, String name) async {
    if (busy || _disposed) return;
    recordAppEvent('Outgoing phone button pressed');
    final call = _Call(++_nextToken, chat, name, VoicePhase.starting);
    _set(call);
    await _start(call);
  }

  Future<void> accept() async {
    final call = _active;
    if (call == null || call.phase != VoicePhase.incoming) return;
    recordAppEvent('Incoming call answer button pressed');
    _phase(call, VoicePhase.starting);
    await _start(call);
  }

  Future<void> _start(_Call call) async {
    try {
      recordAppEvent('Requesting call microphone access');
      final permission = await _host.invokeMethod<bool>('requestMicrophone');
      if (_active != call) return;
      if (permission != true) {
        recordAppEvent('Call microphone access denied');
        _end(call, message: 'Allow microphone access to use voice calls.');
        return;
      }
      recordAppEvent('Loading call relay settings');
      final ice = await _chatmail.iceServers();
      if (_active != call) return;
      if (call.message case final id? when call.offer != null) {
        if (!await _chatmail.callIsRinging(id)) {
          _end(call, signal: false, message: 'This call has ended.');
          return;
        }
      }
      if (_active != call) return;
      recordAppEvent('Starting Android call media');
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
        recordAppEvent('Sending call answer through Chatmail');
        await _chatmail.acceptCall(call.message!, sdp!);
        recordAppEvent('Chatmail queued the call answer');
      } else {
        recordAppEvent('Sending call offer through Chatmail');
        final message = await _chatmail.placeCall(call.chat, sdp!);
        recordAppEvent('Chatmail queued the call offer');
        if (_active != call) {
          unawaited(_signalEnd(message));
          return;
        }
        call.message = message;
        if (_ended.contains(message)) {
          _end(call, signal: false);
          return;
        }
        _phase(call, VoicePhase.ringing);
        if (call.earlyAnswer case final event?) {
          call.earlyAnswer = null;
          await _event(event);
        }
      }
    } on PlatformException catch (issue) {
      recordAppEvent('Android call startup returned an error');
      _end(call, message: issue.message ?? 'Couldn’t start the voice call.');
    } catch (error) {
      recordAppEvent('Call setup error ${error.runtimeType}');
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
        await _incoming(chat, id);
      case 'OutgoingCallAccepted':
        if (call != null &&
            call.chat == chat &&
            call.phase == VoicePhase.starting &&
            call.message == null &&
            call.offer == null) {
          call.earlyAnswer = event;
          return;
        }
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
        recordAppEvent('Received the remote call answer');
        _phase(call, VoicePhase.connecting);
        try {
          await _host.invokeMethod<void>('voiceAnswer', {
            'token': call.token,
            'answer': answer,
          });
          recordAppEvent('Applied the remote WebRTC answer');
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
      recordAppEvent('Incoming call is ringing');
      _set(
        _Call(
          ++_nextToken,
          chat,
          offer.name,
          VoicePhase.incoming,
          message: id,
          offer: offer.offer,
          ringSeconds: offer.secondsLeft,
          incomingVideo: offer.video,
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
      case 'videoAvailable':
      case 'videoUnavailable':
        call.canVideo = data['status'] == 'videoAvailable';
        notifyListeners();
      case 'cameraOn':
      case 'cameraOff':
        call.camera = data['status'] == 'cameraOn';
        notifyListeners();
      case 'remoteCameraOn':
      case 'remoteCameraOff':
        call.remoteCamera = data['status'] == 'remoteCameraOn';
        notifyListeners();
      case 'cameraError':
        call.camera = false;
        call.cameraError = 'Couldn’t start or keep the camera open.';
        notifyListeners();
      case 'failed':
        _end(
          call,
          message: data['message'] as String? ?? 'The voice call stopped.',
        );
    }
  }

  Future<void> toggleSelfPreview() async {
    final call = _active;
    if (call == null || !call.camera) return;
    final next = !call.selfPreview;
    try {
      await _host.invokeMethod<void>('voiceSelfPreview', next);
      if (_active != call) return;
      call.selfPreview = next;
      notifyListeners();
    } on PlatformException {
      return;
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
    // A chat composer may still own the keyboard when an incoming call covers it.
    FocusManager.instance.primaryFocus?.unfocus();
    _active = call;
    _callHidden = false;
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

  void toggleRemoteVideo() {
    final call = _active;
    if (call == null || call.camera || !call.remoteCamera) return;
    call.voiceOnly = !call.voiceOnly;
    notifyListeners();
  }

  Future<void> toggleVideoMode() async {
    final call = _active;
    if (call == null || call.changingCamera) return;
    if (!call.camera &&
        call.remoteCamera &&
        (!call.voiceOnly || !call.resumeLocalVideo || !call.canVideo)) {
      toggleRemoteVideo();
    } else {
      await changeCamera();
    }
  }

  Future<void> changeCamera() async {
    final call = _active;
    if (call == null || !call.canVideo || call.changingCamera) return;
    final enabled = !call.camera;
    call.changingCamera = true;
    call.cameraError = null;
    notifyListeners();
    try {
      if (enabled) {
        final allowed = await _host.invokeMethod<bool>('requestCallCamera');
        if (_active != call) return;
        if (allowed != true) {
          call.cameraError =
              'Allow camera access in Settings → Setup to use video.';
          return;
        }
      }
      final changed = await _host.invokeMethod<bool>('voiceCamera', {
        'token': call.token,
        'value': enabled,
      });
      if (_active == call) {
        if (changed == true) {
          call.voiceOnly = !enabled;
          call.resumeLocalVideo = !enabled;
        } else {
          call.cameraError = enabled
              ? 'Couldn’t open the camera. The call can continue with audio.'
              : 'Couldn’t turn off the camera.';
        }
      }
    } catch (_) {
      if (_active == call) call.cameraError = 'Couldn’t change the camera.';
    } finally {
      if (_active == call) {
        call.changingCamera = false;
        notifyListeners();
      }
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

class _CallDialer extends StatelessWidget {
  const _CallDialer({required this.name, this.photo});

  final String name;
  final String? photo;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Voice call')),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight,
              minWidth: constraints.maxWidth,
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      ChatAvatar(name, photo: photo, radius: 36),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: _CallAction(
                      label: 'Call',
                      icon: Icons.call,
                      onPressed: () => Navigator.of(context).pop(true),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

double _callActionInset(double height) =>
    (height * .13).clamp(12.0, 104.0).toDouble();

class _CallAction extends StatelessWidget {
  const _CallAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    style: FilledButton.styleFrom(
      backgroundColor: destructive
          ? const Color(0xffb83243)
          : const Color(0xff1b663c),
      foregroundColor: Colors.white,
      minimumSize: const Size(152, 52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    icon: Icon(icon),
    label: Text(label),
    onPressed: onPressed,
  );
}

class VoicePanel extends StatelessWidget {
  const VoicePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final calls = VoiceScope.of(context);
    final call = calls?._active;
    final error = calls?.error;
    if (call == null) {
      if (error == null) return const SizedBox.shrink();
      return Align(
        alignment: Alignment.topCenter,
        child: SafeArea(
          child: Card(
            child: ListTile(
              title: Text(error, semanticsLabel: error),
              trailing: IconButton(
                tooltip: 'Dismiss call message',
                onPressed: calls!.clearError,
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        ),
      );
    }

    final controller = calls!;
    if (controller._callHidden) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final incoming = call.phase == VoicePhase.incoming;
    final connected = call.phase == VoicePhase.connected;
    final remoteVisible = call.remoteCamera && !call.voiceOnly;
    final previewVisible = call.camera && call.selfPreview && !call.voiceOnly;
    final videoVisible = remoteVisible || (call.camera && !call.voiceOnly);
    final status = switch (call.phase) {
      VoicePhase.incoming =>
        call.incomingVideo
            ? 'Incoming video call from ${call.name}'
            : 'Incoming call from ${call.name}',
      VoicePhase.starting => 'Preparing call…',
      VoicePhase.ringing => 'Calling ${call.name}…',
      VoicePhase.connecting => 'Connecting to ${call.name}…',
      VoicePhase.connected =>
        videoVisible
            ? 'Video call with ${call.name}'
            : 'Voice call with ${call.name}',
    };

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: 'Call controls',
      explicitChildNodes: true,
      child: BlockSemantics(
        child: Material(
          color: remoteVisible ? Colors.black : colors.surface,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                fit: StackFit.expand,
                children: [
                  if (remoteVisible || previewVisible) const _CallVideo(),
                  if (!remoteVisible)
                    Center(
                      child: CircleAvatar(
                        radius: 40,
                        backgroundColor: colors.secondaryContainer,
                        foregroundColor: colors.onSecondaryContainer,
                        child: Icon(
                          call.incomingVideo
                              ? Icons.videocam_outlined
                              : Icons.person_outline,
                          size: 40,
                        ),
                      ),
                    ),
                  Positioned(
                    top: 10,
                    left: 12,
                    right: 12,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            status,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  color: remoteVisible
                                      ? Colors.white
                                      : colors.onSurface,
                                  shadows: remoteVisible
                                      ? _videoControlShadows
                                      : null,
                                ),
                          ),
                        ),
                        if (controller._visibleGames.isNotEmpty && !incoming)
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: remoteVisible
                                  ? Colors.white
                                  : ZompadoBrand.actionInk(colors),
                            ),
                            onPressed: controller._hideCall,
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.sports_esports_outlined, size: 34),
                                Text(
                                  'Return to game',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                Text('Call stays connected'),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 4,
                    right: 4,
                    bottom: incoming
                        ? 4
                        : _callActionInset(constraints.maxHeight),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (call.cameraError case final issue?)
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              issue,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: remoteVisible
                                    ? Colors.white
                                    : colors.onSurface,
                                shadows: remoteVisible
                                    ? _videoControlShadows
                                    : null,
                              ),
                            ),
                          ),
                        if (connected || incoming)
                          IconTheme.merge(
                            data: IconThemeData(
                              color: remoteVisible
                                  ? Colors.white
                                  : colors.onSurface,
                              shadows: remoteVisible
                                  ? _videoControlShadows
                                  : null,
                            ),
                            child: DefaultTextStyle.merge(
                              style: TextStyle(
                                color: remoteVisible
                                    ? Colors.white
                                    : colors.onSurface,
                                shadows: remoteVisible
                                    ? _videoControlShadows
                                    : null,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (connected) ...[
                                    _VoiceButton(
                                      tooltip: call.muted
                                          ? 'Unmute microphone'
                                          : 'Mute microphone',
                                      label: call.muted ? 'Unmute' : 'Mute',
                                      onPressed: () => controller.changeAudio(
                                        speaker: false,
                                      ),
                                      icon: call.muted
                                          ? Icons.mic_off
                                          : Icons.mic_none,
                                      selected: call.muted,
                                    ),
                                    _VoiceButton(
                                      tooltip: call.speaker
                                          ? 'Turn off speaker'
                                          : 'Turn on speaker',
                                      label: 'Speaker',
                                      onPressed: () =>
                                          controller.changeAudio(speaker: true),
                                      icon: call.speaker
                                          ? Icons.volume_up
                                          : Icons.volume_down_outlined,
                                      selected: call.speaker,
                                    ),
                                    if (call.canVideo ||
                                        call.remoteCamera ||
                                        call.camera)
                                      _VoiceButton(
                                        tooltip: videoVisible
                                            ? 'Switch to audio'
                                            : 'Switch to video',
                                        label: videoVisible ? 'Audio' : 'Video',
                                        onPressed: call.changingCamera
                                            ? null
                                            : controller.toggleVideoMode,
                                        icon: videoVisible
                                            ? Icons.call_outlined
                                            : Icons.videocam_outlined,
                                      ),
                                    if (videoVisible && call.camera)
                                      _VoiceButton(
                                        tooltip: call.selfPreview
                                            ? 'Hide preview'
                                            : 'Show preview',
                                        label: 'Preview',
                                        onPressed: controller.toggleSelfPreview,
                                        icon: call.selfPreview
                                            ? Icons.picture_in_picture_alt
                                            : Icons
                                                  .picture_in_picture_alt_outlined,
                                        selected: call.selfPreview,
                                      )
                                    else if (remoteVisible && call.canVideo)
                                      _VoiceButton(
                                        tooltip: 'Turn on camera',
                                        label: 'Camera',
                                        onPressed: call.changingCamera
                                            ? null
                                            : controller.changeCamera,
                                        icon: Icons.videocam_outlined,
                                      ),
                                  ],
                                  if (incoming)
                                    _VoiceButton(
                                      tooltip: 'Decline',
                                      label: 'Decline',
                                      onPressed: controller.hangUp,
                                      color: colors.error,
                                      icon: Icons.call_end,
                                    ),
                                  if (incoming)
                                    _VoiceButton(
                                      tooltip: 'Answer',
                                      label: 'Answer',
                                      onPressed: controller.accept,
                                      color: const Color(0xff43b981),
                                      icon: Icons.call,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (!incoming) ...[
                          if (connected) const SizedBox(height: 12),
                          _CallAction(
                            label: 'End call',
                            icon: Icons.call_end,
                            onPressed: controller.hangUp,
                            destructive: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CallVideo extends StatelessWidget {
  const _CallVideo();

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.expand();
    }
    const viewType = 'io.zompado.callVideo';
    return PlatformViewLink(
      viewType: viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          onFocus: () => params.onFocusChanged(true),
        );
        unawaited(controller.create());
        return controller
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
      },
    );
  }
}

const _videoControlShadows = [Shadow(color: Colors.black, blurRadius: 6)];

class _VoiceButton extends StatelessWidget {
  const _VoiceButton({
    required this.tooltip,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.color,
    this.selected = false,
  });

  final String tooltip, label;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool selected;

  @override
  Widget build(BuildContext context) => Flexible(
    child: SizedBox(
      width: 82,
      child: Semantics(
        container: true,
        label: tooltip,
        button: true,
        selected: selected,
        onTap: onPressed,
        child: ExcludeSemantics(
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 30, color: color),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
