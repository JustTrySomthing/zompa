import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_preview.dart';
import 'chatmail.dart';
import 'saved_messages.dart';

class ChatGallery extends StatefulWidget {
  const ChatGallery({
    super.key,
    required this.chatmail,
    required this.chat,
    this.active = true,
  });

  final Chatmail chatmail;
  final int chat;
  final bool active;

  @override
  State<ChatGallery> createState() => _ChatGalleryState();
}

class _ChatGalleryState extends State<ChatGallery> {
  static const _pageSize = 45;
  int _limit = _pageSize;
  ChatMediaFilter _filter = ChatMediaFilter.all;
  List<FriendMessage> _items = [];
  bool _hasOlder = false;
  bool _loaded = false;
  bool _failed = false;
  bool _needsRefresh = false;
  Future<void>? _loading;
  Timer? _debounce;
  late final StreamSubscription<void> _updates;
  final _saving = <int>{};

  @override
  void initState() {
    super.initState();
    _updates = widget.chatmail.changes.listen((_) {
      _needsRefresh = true;
      if (!widget.active) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 220), _refresh);
    });
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(ChatGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) _debounce?.cancel();
    if (!oldWidget.active && widget.active && _needsRefresh) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_updates.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    // A refresh after a save must run after any previous read has finished.
    final filter = _filter;
    while (mounted && _loading != null && filter == _filter) {
      await _loading;
    }
    if (!mounted || filter != _filter) return;
    _needsRefresh = false;
    final pending = _load(filter);
    setState(() {
      _loading = pending;
    });
    await pending;
    if (mounted) setState(() => _loading = null);
  }

  Future<void> _load(ChatMediaFilter filter) async {
    try {
      final result = await (filter == ChatMediaFilter.all
          ? widget.chatmail.chatMedia(widget.chat, limit: _limit)
          : widget.chatmail.filteredChatMedia(
              widget.chat,
              limit: _limit,
              filter: filter,
            ));
      if (!mounted || _filter != filter) return;
      setState(() {
        _items = result.messages;
        _hasOlder = result.hasOlder;
        _loaded = true;
        _failed = false;
      });
    } catch (_) {
      if (mounted && _filter == filter) setState(() => _failed = true);
    }
  }

  void _selectFilter(ChatMediaFilter filter) {
    if (filter == _filter) return;
    setState(() {
      _filter = filter;
      _limit = _pageSize;
      _items = [];
      _hasOlder = false;
      _loaded = false;
      _failed = false;
    });
    unawaited(_refresh());
  }

  Future<void> _loadOlder() async {
    _limit += _pageSize;
    await _refresh();
  }

  Future<void> _save(FriendMessage message) async {
    if (!_saving.add(message.id)) return;
    setState(() {});
    try {
      await widget.chatmail.toggleSaved(message);
      await _refresh();
      if (mounted && _failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Saved was updated. Couldn’t refresh media.'),
            action: SnackBarAction(label: 'Retry', onPressed: _refresh),
          ),
        );
      }
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
  Widget build(BuildContext context) => Column(
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
        child: Row(
          children: [
            for (final filter in ChatMediaFilter.values)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: ChoiceChip(
                  label: Text(filter.label),
                  showCheckmark: false,
                  selected: _filter == filter,
                  onSelected: (_) => _selectFilter(filter),
                ),
              ),
          ],
        ),
      ),
      Expanded(child: _gallery()),
    ],
  );

  Widget _gallery() => LayoutBuilder(
    builder: (context, bounds) {
      final artHeight = (bounds.maxWidth / 3).clamp(90.0, 180.0);
      final labelHeight = MediaQuery.textScalerOf(context).scale(12) * 3.6;
      return CustomScrollView(
        key: PageStorageKey(('chat-media', widget.chat, _filter)),
        primary: false,
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
                    saving: _failed || _saving.contains(message.id),
                    onSave: () => _save(message),
                  );
                },
              ),
            ),
          if (_failed || _items.isEmpty || _hasOlder)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: _loading != null && _items.isEmpty
                      ? const LinearProgressIndicator()
                      : _failed
                      ? TextButton(
                          onPressed: _loading == null ? _refresh : null,
                          child: const Text('Couldn’t load media. Retry'),
                        )
                      : _hasOlder
                      ? TextButton(
                          onPressed: _loading == null ? _loadOlder : null,
                          child: const Text('Load older attachments'),
                        )
                      : _loaded
                      ? Text(
                          _filter == ChatMediaFilter.all
                              ? 'No attachments in this chat yet.'
                              : 'No matching attachments in this chat.',
                        )
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
              iconSize: 25,
              style: IconButton.styleFrom(padding: const EdgeInsets.all(7)),
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
