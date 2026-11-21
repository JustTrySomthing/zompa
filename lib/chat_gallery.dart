import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_preview.dart';
import 'chatmail.dart';
import 'saved_messages.dart';

class ChatGallery extends StatefulWidget {
  const ChatGallery({super.key, required this.chatmail, required this.chat});

  final Chatmail chatmail;
  final int chat;

  @override
  State<ChatGallery> createState() => _ChatGalleryState();
}

class _ChatGalleryState extends State<ChatGallery> {
  static const _pageSize = 45;
  int _limit = _pageSize;
  List<FriendMessage> _items = [];
  bool _hasOlder = false;
  bool _loaded = false;
  bool _failed = false;
  Future<void>? _loading;
  Timer? _debounce;
  late final StreamSubscription<void> _updates;
  final _saving = <int>{};

  @override
  void initState() {
    super.initState();
    _updates = widget.chatmail.changes.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 220), _refresh);
    });
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_updates.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    // A refresh after a save must run after any previous read has finished.
    while (mounted && _loading != null) {
      await _loading;
    }
    if (!mounted) return;
    final pending = _load();
    setState(() {
      _loading = pending;
    });
    await pending;
    if (mounted) setState(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final result = await widget.chatmail.chatMedia(
        widget.chat,
        limit: _limit,
      );
      if (!mounted) return;
      setState(() {
        _items = result.messages;
        _hasOlder = result.hasOlder;
        _loaded = true;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _save(FriendMessage message) async {
    if (!_saving.add(message.id)) return;
    setState(() {});
    try {
      await widget.chatmail.toggleSaved(message);
      await _refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t update Saved. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(message.id));
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final artHeight = (bounds.maxWidth / 3).clamp(90.0, 180.0);
      final labelHeight = MediaQuery.textScalerOf(context).scale(12) * 3.6;
      return CustomScrollView(
        key: PageStorageKey('chat-media-${widget.chat}'),
        slivers: [
          if (_items.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                  mainAxisExtent: artHeight + labelHeight,
                ),
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final message = _items[index];
                  return _MediaCard(
                    key: ValueKey((message.id, message.file)),
                    message: message,
                    saving: _saving.contains(message.id),
                    onSave: () => _save(message),
                  );
                },
              ),
            ),
          if (_loading != null || _failed || _items.isEmpty || _hasOlder)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: _loading != null
                      ? const LinearProgressIndicator()
                      : _failed
                      ? TextButton(
                          onPressed: _refresh,
                          child: const Text('Couldn’t load media. Retry'),
                        )
                      : _hasOlder
                      ? TextButton(
                          onPressed: () {
                            _limit += _pageSize;
                            unawaited(_refresh());
                          },
                          child: const Text('Load older attachments'),
                        )
                      : _loaded
                      ? const Text('No attachments in this chat yet.')
                      : const SizedBox.shrink(),
                ),
              ),
            ),
        ],
      );
    },
  );
}

String _sizeLabel(int? bytes) {
  if (bytes == null || bytes < 0) return 'Size unavailable';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _MediaCard extends StatelessWidget {
  const _MediaCard({
    super.key,
    required this.message,
    required this.saving,
    required this.onSave,
  });

  final FriendMessage message;
  final bool saving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final path = message.file!;
    final media = message.media;
    final name = message.filename ?? path.split(Platform.pathSeparator).last;
    final size = _sizeLabel(message.fileBytes);
    final visual = media == ChatMedia.image || media == ChatMedia.video;
    final saved = message.savedId != null;
    void open() => unawaited(
      openChatAttachment(
        context,
        message,
        filePreview: media == null
            ? _FilePreview(message: message, size: size, name: name)
            : null,
      ),
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: colors.surfaceContainerHigh,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Semantics(
            button: true,
            label: 'Open $name, $size',
            onTap: open,
            excludeSemantics: true,
            child: InkWell(
              onTap: open,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: switch (media) {
                      ChatMedia.image => Image.file(
                        File(path),
                        cacheWidth: 320,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Center(
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      ),
                      ChatMedia.video => Stack(
                        fit: StackFit.expand,
                        children: [
                          ChatVideoThumbnail(path),
                          const Align(
                            alignment: Alignment(0, .35),
                            child: Icon(
                              Icons.play_circle_filled,
                              color: Colors.white,
                              shadows: [Shadow(blurRadius: 8)],
                            ),
                          ),
                        ],
                      ),
                      ChatMedia.audio => const Padding(
                        padding: EdgeInsets.fromLTRB(10, 47, 10, 4),
                        child: Column(
                          children: [
                            Expanded(child: Icon(Icons.play_circle_outline)),
                            LinearProgressIndicator(value: 0),
                          ],
                        ),
                      ),
                      null => const Padding(
                        padding: EdgeInsets.only(top: 22),
                        child: Icon(Icons.insert_drive_file_outlined),
                      ),
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 3, 6, 6),
                    child: Column(
                      children: [
                        if (!visual)
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall,
                          ),
                        Text(
                          size,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          PositionedDirectional(
            top: 2,
            end: 2,
            child: IconButton.filledTonal(
              tooltip: saved ? 'Unsave attachment' : 'Save attachment',
              onPressed: saving ? null : onSave,
              iconSize: 19,
              icon: Icon(saved ? Icons.star : Icons.star_border),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilePreview extends StatelessWidget {
  const _FilePreview({
    required this.message,
    required this.size,
    required this.name,
  });

  final FriendMessage message;
  final String size, name;

  Future<void> _open(BuildContext context) async {
    try {
      final opened = await const MethodChannel('io.zompado.host')
          .invokeMethod<bool>('openChatAttachment', {
            'path': message.file,
            'mime': message.mime,
          });
      if (opened == true) return;
    } on PlatformException {
      // Keep the file available for download if Android can't open it.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No app could open this file.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 52),
          const SizedBox(height: 12),
          Text(name, textAlign: TextAlign.center),
          Text(size),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              FilledButton(
                onPressed: () => _open(context),
                child: const Text('Open with…'),
              ),
              OutlinedButton(
                onPressed: () => downloadChatFile(context, message),
                child: const Text('Download'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
