import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import 'chat_chrome.dart';
import 'chatmail.dart';
import 'message_bubble.dart';

const _host = MethodChannel('io.zompado.host');

class ChatAttachment extends StatelessWidget {
  const ChatAttachment(this.message, {super.key});

  final FriendMessage message;

  @override
  Widget build(BuildContext context) {
    final file = message.file;
    if (file == null) return const SizedBox.shrink();
    final path = File(file);
    final mime = message.mime ?? '';
    final image =
        mime.startsWith('image/') ||
        const {'Image', 'Gif', 'Sticker'}.contains(message.viewType);
    final title = message.filename ?? (image ? 'Image' : 'Video');
    if (image) {
      return Semantics(
        button: true,
        label: 'Open image preview',
        child: InkWell(
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => _ImagePreview(path, title)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              path,
              cacheWidth: 640,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Text('Image unavailable'),
            ),
          ),
        ),
      );
    }
    if (mime.startsWith('video/') || message.viewType == 'Video') {
      return _VideoAttachment(key: ValueKey(file), path: file, title: title);
    }
    if (mime.startsWith('audio/') ||
        const {'Audio', 'Voice'}.contains(message.viewType)) {
      return _AudioAttachment(key: ValueKey(file), path: file);
    }
    return const SizedBox.shrink();
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview(this.file, this.title);

  final File file;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title), actions: chatActions(context)),
    body: SafeArea(
      child: SizedBox.expand(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Center(
            child: Image.file(
              file,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Text('Image unavailable'),
            ),
          ),
        ),
      ),
    ),
  );
}

class _VideoAttachment extends StatefulWidget {
  const _VideoAttachment({super.key, required this.path, required this.title});

  final String path, title;

  @override
  State<_VideoAttachment> createState() => _VideoAttachmentState();
}

class _VideoAttachmentState extends State<_VideoAttachment> {
  late final _thumbnail = _host.invokeMethod<Uint8List>(
    'chatVideoThumbnail',
    widget.path,
  );

  @override
  Widget build(BuildContext context) {
    void open() => Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(widget.title),
            actions: chatActions(context),
          ),
          body: SafeArea(
            child: _PreviewSurface('io.zompado.chatVideo', widget.path),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: open,
          child: _Thumbnail(
            child: FutureBuilder<Uint8List?>(
              future: _thumbnail,
              builder: (context, frame) => frame.data == null
                  ? const Center(child: Icon(Icons.movie_outlined, size: 42))
                  : Image.memory(frame.data!, fit: BoxFit.cover),
            ),
          ),
        ),
        TextButton.icon(
          onPressed: open,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Play video'),
        ),
      ],
    );
  }
}

class _AudioAttachment extends StatefulWidget {
  const _AudioAttachment({super.key, required this.path});

  final String path;

  @override
  State<_AudioAttachment> createState() => _AudioAttachmentState();
}

class _AudioAttachmentState extends State<_AudioAttachment> {
  static int _nextToken = 0;
  final int _token = ++_nextToken;
  Timer? _timer;
  bool _requesting = false;
  bool _playing = false;
  bool _loading = false;
  bool _error = false;
  int _duration = 0;
  int _position = 0;
  double? _seek;

  Future<void> _update() async {
    if (_requesting || !mounted) return;
    _requesting = true;
    try {
      if (ModalRoute.of(context)?.isCurrent == false) {
        await _host.invokeMethod<void>('chatAudioStop', _token);
      }
      final status = await _host.invokeMapMethod<String, Object>(
        'chatAudioStatus',
        _token,
      );
      if (!mounted || status == null) return;
      if (status['active'] != true) {
        _timer?.cancel();
        _timer = null;
      }
      setState(() {
        _playing = status['playing'] == true;
        _loading = status['loading'] == true;
        _error = status['error'] == true;
        _duration = status['duration'] as int? ?? _duration;
        _position = status['position'] as int? ?? 0;
      });
    } on PlatformException {
      if (mounted) setState(() => _error = true);
    } finally {
      _requesting = false;
    }
  }

  Future<void> _toggle() async {
    setState(() => _loading = true);
    try {
      await _host.invokeMethod<void>('chatAudioToggle', {
        'path': widget.path,
        'token': _token,
      });
      if (!mounted) {
        unawaited(_host.invokeMethod<void>('chatAudioStop', _token));
        return;
      }
      _timer ??= Timer.periodic(
        const Duration(milliseconds: 400),
        (_) => _update(),
      );
      await _update();
    } on PlatformException {
      if (mounted)
        setState(() {
          _loading = false;
          _error = true;
        });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_timer != null || _loading)
      unawaited(_host.invokeMethod<void>('chatAudioStop', _token));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _error
      ? TextButton.icon(
          onPressed: _toggle,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry audio'),
        )
      : Row(
          children: [
            IconButton(
              color: Theme.of(context).colorScheme.primary,
              tooltip: _playing ? 'Pause audio' : 'Play audio',
              onPressed: _loading ? null : _toggle,
              icon: Icon(
                _playing
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
              ),
            ),
            Expanded(
              child: Slider(
                value: (_seek ?? _position.toDouble())
                    .clamp(0, _duration)
                    .toDouble(),
                max: _duration > 0 ? _duration.toDouble() : 1,
                onChanged: _duration > 0 && _timer != null
                    ? (value) => setState(() => _seek = value)
                    : null,
                onChangeEnd: (value) async {
                  await _host.invokeMethod<void>('chatAudioSeek', {
                    'token': _token,
                    'position': value.round(),
                  });
                  if (!mounted) return;
                  setState(() => _seek = null);
                  unawaited(_update());
                },
              ),
            ),
            if (_duration > 0) Text(_clock(_playing ? _position : _duration)),
          ],
        );

  String _clock(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: AspectRatio(aspectRatio: 16 / 9, child: child),
    ),
  );
}

class ChatText extends StatefulWidget {
  const ChatText(this.text, {super.key, required this.size});

  final String text;
  final double size;

  @override
  State<ChatText> createState() => _ChatTextState();
}

class _ChatTextState extends State<ChatText> {
  static final _web = RegExp(
    r'https?://[^\s<>"\u0000-\u001f]+',
    caseSensitive: false,
  );
  final _links = <(int, int, Uri, TapGestureRecognizer)>[];

  @override
  void initState() {
    super.initState();
    _parseLinks();
  }

  @override
  void didUpdateWidget(covariant ChatText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _parseLinks();
  }

  void _parseLinks() {
    _clearLinks();
    for (final match in _web.allMatches(widget.text)) {
      final text = match.group(0)!.replaceFirst(RegExp(r'[.,!?;)\]}]+$'), '');
      final url = Uri.tryParse(text);
      if (url == null || url.host.isEmpty || url.userInfo.isNotEmpty) continue;
      _links.add((
        match.start,
        match.start + text.length,
        url,
        TapGestureRecognizer()..onTap = () => _openBrowser(context, url),
      ));
    }
  }

  void _clearLinks() {
    for (final (_, _, _, tap) in _links) {
      tap.dispose();
    }
    _links.clear();
  }

  @override
  void dispose() {
    _clearLinks();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_links.isEmpty) return MessageBody(widget.text, size: widget.size);
    final primary = Theme.of(context).colorScheme.primary;
    var last = 0;
    final spans = <InlineSpan>[];
    (Uri, String)? video;
    for (final (start, end, url, tap) in _links) {
      spans.add(TextSpan(text: widget.text.substring(last, start)));
      spans.add(
        TextSpan(
          text: widget.text.substring(start, end),
          style: TextStyle(
            color: primary,
            decoration: TextDecoration.underline,
            decorationColor: primary,
          ),
          recognizer: tap,
        ),
      );
      last = end;
      if (_youtubeId(url) case final id? when video == null) {
        video = (url, id);
      }
    }
    spans.add(TextSpan(text: widget.text.substring(last)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text.rich(
          TextSpan(children: spans),
          style: TextStyle(fontSize: widget.size, height: 1.4),
        ),
        if (video case (final url, final id)) ...[
          const SizedBox(height: 8),
          InkWell(
            onTap: () => _openBrowser(context, url),
            child: _Thumbnail(
              child: Image.network(
                'https://i.ytimg.com/vi/$id/hqdefault.jpg',
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Center(
                  child: Icon(Icons.ondemand_video_outlined, size: 42),
                ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => _openBrowser(context, url),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play YouTube video'),
          ),
        ],
      ],
    );
  }
}

String? _youtubeId(Uri uri) {
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments;
  final String? id;
  if (host == 'youtu.be' && segments.isNotEmpty) {
    id = segments.first;
  } else if (const {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
  }.contains(host)) {
    id = switch (segments) {
      ['watch'] => uri.queryParameters['v'],
      ['shorts' || 'embed' || 'live', final video, ...] => video,
      _ => null,
    };
  } else {
    return null;
  }
  return id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ? id : null;
}

void _openBrowser(BuildContext context, Uri url) {
  final id = _youtubeId(url);
  final target = id == null
      ? url
      : Uri.https('m.youtube.com', '/watch', {'v': id, 'autoplay': '1'});
  Navigator.of(context)
      .push<void>(MaterialPageRoute(builder: (_) => _BrowserPreview(target)));
}

class _BrowserPreview extends StatefulWidget {
  const _BrowserPreview(this.url);

  final Uri url;

  @override
  State<_BrowserPreview> createState() => _BrowserPreviewState();
}

class _BrowserPreviewState extends State<_BrowserPreview> {
  int? _viewId;

  Future<void> _external() async {
    final opened = await _host.invokeMethod<bool>('openPreviewExternal', {
      'id': _viewId,
      'url': widget.url.toString(),
    });
    if (opened != true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Couldn’t open a browser.')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Preview Browser'),
      actions: [
        ...chatActions(context),
        IconButton(
          onPressed: _external,
          icon: const Icon(Icons.open_in_new),
          tooltip: 'Open in default browser',
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.language),
            title: Text(widget.url.host),
          ),
          Expanded(
            child: _PreviewSurface(
              'io.zompado.previewBrowser',
              widget.url.toString(),
              onCreated: (id) => _viewId = id,
            ),
          ),
        ],
      ),
    ),
  );
}

class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface(this.type, this.value, {this.onCreated});

  final String type, value;
  final ValueChanged<int>? onCreated;

  @override
  Widget build(BuildContext context) => PlatformViewLink(
    viewType: type,
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      gestureRecognizers: const {},
    ),
    onCreatePlatformView: (params) {
      final controller = PlatformViewsService.initExpensiveAndroidView(
        id: params.id,
        viewType: type,
        layoutDirection: Directionality.of(context),
        creationParams: value,
        creationParamsCodec: const StandardMessageCodec(),
        onFocus: () => params.onFocusChanged(true),
      );
      controller.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
      if (onCreated case final onCreated?) {
        controller.addOnPlatformViewCreatedListener(onCreated);
      }
      unawaited(controller.create());
      return controller;
    },
  );
}
