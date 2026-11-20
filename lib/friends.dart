import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chatmail.dart';
import 'chat_files.dart';
import 'chat_emoji.dart';
import 'chat_avatar.dart';
import 'chat_chrome.dart';
import 'message_bubble.dart';
import 'chat_preview.dart';
import 'game_link.dart';
import 'github_distribution.dart';
import 'online_match.dart';
import 'online_match_page.dart';
import 'saved_messages.dart';
import 'voice_calls.dart';

String _failure(Object error) => switch (error) {
  ChatmailIssue.invite => 'Use the invite link from a friend’s Invite screen.',
  ChatmailIssue.encrypted => 'Wait for your friend connection to finish.',
  ChatmailIssue.unavailable =>
    'The Chatmail connection stopped. Retry from Chats.',
  TimeoutException() => 'Chatmail took too long to respond. Try again.',
  _ => 'Chatmail couldn’t complete this action. Check your connection and try again.',
};

class FriendsPane extends StatefulWidget {
  const FriendsPane({
    super.key,
    required this.chatmail,
    required this.pickGameLink,
    required this.openGameLink,
    required this.prepareGame,
  });

  final Chatmail chatmail;
  final Future<String?> Function() pickGameLink;
  final Future<void> Function(GameLink) openGameLink;
  final Future<GameRelease?> Function(GameLink) prepareGame;

  @override
  State<FriendsPane> createState() => _FriendsPaneState();
}

enum _ChatFolder { inbox, archive, trash }

class _FriendsPaneState extends State<FriendsPane> {
  final _name = TextEditingController();
  List<FriendChat> _chats = [];
  StreamSubscription<void>? _events;
  Timer? _refreshTimer;
  bool _ready = false;
  _ChatFolder _folder = _ChatFolder.inbox;
  bool _busy = true;
  bool _refreshing = false;
  bool _refreshQueued = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _events = widget.chatmail.changes.listen((_) {
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(milliseconds: 220), () {
        if (!_ready && !_busy && mounted) {
          _initialize();
        } else {
          _refresh();
        }
      });
    });
    _initialize();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _events?.cancel();
    _name.dispose();
    super.dispose();
  }

  Future<void> _initialize() => _perform(() async {
    _ready = await widget.chatmail.restore();
    if (_ready) _chats = await _loadFolder(_folder);
  });

  Future<void> _perform(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = _failure(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (!_ready || !mounted) return;
    if (_refreshing) {
      _refreshQueued = true;
      return;
    }
    _refreshing = true;
    try {
      final folder = _folder;
      final chats = await _loadFolder(folder);
      if (mounted && folder == _folder)
        setState(() {
          _chats = chats;
          if (!_busy) _error = null;
        });
    } catch (error) {
      if (mounted && !_busy) setState(() => _error = _failure(error));
    } finally {
      _refreshing = false;
      if (_refreshQueued) {
        _refreshQueued = false;
        unawaited(_refresh());
      }
    }
  }

  void _setup() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a display name first.');
      return;
    }
    _perform(() async {
      await widget.chatmail.createProfile(name);
      _ready = true;
      _chats = await _loadFolder(_folder);
    });
  }

  Future<void> _open(int chat, String name) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FriendConversation(
          chatmail: widget.chatmail,
          id: chat,
          initialName: name,
          pickGameLink: widget.pickGameLink,
          openGameLink: widget.openGameLink,
          prepareGame: widget.prepareGame,
        ),
      ),
    );
    await _refresh();
  }

  Future<List<FriendChat>> _loadFolder(_ChatFolder folder) =>
      widget.chatmail.chats(
        archived: folder == _ChatFolder.archive,
        trash: folder == _ChatFolder.trash,
      );

  void _selectFolder(_ChatFolder folder) {
    if (_folder == folder) return;
    setState(() {
      _folder = folder;
      _chats = [];
    });
    unawaited(_refresh());
  }

  Future<void> _emptyTrash() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Empty trash?'),
        content: const Text('This permanently deletes all chats in Trash.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Empty trash'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _perform(widget.chatmail.emptyTrash);
    if (mounted) await _refresh();
  }

  Future<void> _chatMenu(FriendChat chat) async {
    final trashed = _folder == _ChatFolder.trash;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text(chat.name),
        children: [
          for (final (value, label, icon)
              in trashed
                  ? [('recover', 'Restore', Icons.restore_from_trash_outlined)]
                  : [
                      (
                        chat.archived ? 'restore' : 'archive',
                        chat.archived ? 'Restore' : 'Archive',
                        Icons.archive_outlined,
                      ),
                      (
                        chat.unread > 0 ? 'read' : 'unread',
                        chat.unread > 0 ? 'Mark read' : 'Mark unread',
                        Icons.mark_email_unread_outlined,
                      ),
                      (
                        chat.muted ? 'unmute' : 'mute',
                        chat.muted
                            ? 'Unmute notifications'
                            : 'Mute notifications',
                        Icons.notifications_off_outlined,
                      ),
                      ('remind', 'Remind me later', Icons.schedule),
                      ('block', 'Block sender', Icons.block),
                      ('delete', 'Delete chat', Icons.delete_outline),
                    ])
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              onTap: () => Navigator.pop(dialog, value),
            ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    if (selected == 'remind') {
      try {
        final thread = await widget.chatmail.thread(chat.id);
        if (!mounted) return;
        final latest = thread.messages.reversed
            .where(
              (message) =>
                  !message.outgoing &&
                  !message.info &&
                  message.viewType != 'Call' &&
                  MatchEvent.parse(message.text) == null,
            )
            .firstOrNull;
        if (latest != null) {
          await showReplyReminder(context, latest);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('There’s no incoming message to reply to.'),
            ),
          );
        }
      } catch (_) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Couldn’t load the latest message.')),
          );
      }
      return;
    }
    if (selected == 'recover') {
      await _perform(() => widget.chatmail.restoreTrash(chat.id));
      if (mounted) await _refresh();
      return;
    }
    if (selected == 'block' || selected == 'delete') {
      final deleting = selected == 'delete';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(
            deleting ? 'Move this chat to Trash?' : 'Block ${chat.name}?',
          ),
          content: Text(
            deleting
                ? 'You can restore this chat from Trash.'
                : 'Messages and calls from this sender will be blocked.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(deleting ? 'Move to Trash' : 'Block'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    await _perform(() => widget.chatmail.manageChat(chat.id, selected));
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (!_ready) ...[
          Text('Set up chats', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Create a profile on Chatmail to connect with friends. Use any display name you want to share.',
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _name,
            enabled: !_busy,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Display name'),
            onSubmitted: (_) {
              if (!_busy) _setup();
            },
          ),
          FilledButton(
            onPressed: _busy ? null : _setup,
            child: const Text('Create chat profile'),
          ),
        ] else ...[
          SegmentedButton<_ChatFolder>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _ChatFolder.inbox, label: Text('Inbox')),
              ButtonSegment(value: _ChatFolder.archive, label: Text('Archive')),
              ButtonSegment(value: _ChatFolder.trash, label: Text('Trash')),
            ],
            selected: {_folder},
            onSelectionChanged: _busy
                ? null
                : (folders) => _selectFolder(folders.single),
          ),
          if (_folder == _ChatFolder.trash)
            Wrap(
              spacing: 10,
              children: [
                TextButton(
                  onPressed: _busy || _chats.isEmpty
                      ? null
                      : () async {
                          await _perform(
                            () => widget.chatmail.restoreTrash(null),
                          );
                          if (mounted) await _refresh();
                        },
                  child: const Text('Restore all'),
                ),
                TextButton(
                  onPressed: _busy || _chats.isEmpty ? null : _emptyTrash,
                  child: const Text('Empty trash'),
                ),
              ],
            ),
          const SizedBox(height: 8),
          if (_chats.isEmpty)
            Text(switch (_folder) {
              _ChatFolder.archive => 'No archived chats.',
              _ChatFolder.trash => 'Trash is empty.',
              _ChatFolder.inbox => 'Use Contacts to connect with a friend.',
            }),
          for (final chat in _chats)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: ListTile(
                  leading: ChatAvatar(chat.name, photo: chat.photo),
                  title: Text(chat.name),
                  subtitle: chat.preview.isEmpty
                      ? null
                      : Text(
                          chat.preview.startsWith(matchMarker.trimRight())
                              ? 'Cats vs Dogs match update'
                              : chat.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: chat.unread > 0
                      ? Semantics(
                          label: '${chat.unread} unread messages',
                          child: Badge.count(count: chat.unread),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _busy
                      ? null
                      : () {
                          if (_folder == _ChatFolder.trash) {
                            _chatMenu(chat);
                          } else {
                            _open(chat.id, chat.name);
                          }
                        },
                  onLongPress: _busy ? null : () => _chatMenu(chat),
                ),
              ),
            ),
        ],
        if (_error case final error?) ...[
          const SizedBox(height: 12),
          Text(error, style: TextStyle(color: theme.colorScheme.error)),
          TextButton(
            onPressed: _busy ? null : _initialize,
            child: const Text('Retry connection'),
          ),
        ],
      ],
    );
  }
}

class ContactInvites {
  ContactInvites(this.context, this.chatmail, this.open, this.share);

  final BuildContext context;
  final Chatmail chatmail;
  final Future<void> Function(int, String) open;
  final Future<void> Function(String) share;

  Future<void> _perform(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_failure(error))));
    }
  }

  Future<void> create() => _perform(() async {
    final invite = await chatmail.invite();
    List<(int, int)> modules = const [];
    try {
      modules = await chatmail.qrModules(invite);
    } catch (_) {
      // Sharing the original invite link remains available.
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Invite a friend'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (modules.isNotEmpty)
              Semantics(
                label: 'Friend invite QR code',
                image: true,
                child: SizedBox(
                  width: 220,
                  height: 220,
                  child: CustomPaint(painter: _InviteQr(modules)),
                ),
              ),
            const Text(
              'Share this invite with a friend. They can open Zompado and paste it under Accept invite.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: invite));
              if (!dialog.mounted) return;
              Navigator.pop(dialog);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Invite copied.')));
            },
            child: const Text('Copy link'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Done'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialog);
              try {
                await share(invite);
              } catch (_) {
                if (context.mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Sharing is unavailable. Use Copy link.'),
                    ),
                  );
              }
            },
            child: const Text('Share'),
          ),
        ],
      ),
    );
  });

  Future<void> accept() async {
    final invite = await showDialog<String>(
      context: context,
      builder: (_) => const _AcceptInviteDialog(),
    );
    if (!context.mounted || invite == null) return;
    await _perform(() async {
      final chat = await chatmail.acceptInvite(invite);
      if (context.mounted) await open(chat, 'Friend');
    });
  }
}

class _InviteQr extends CustomPainter {
  const _InviteQr(this.modules);

  final List<(int, int)> modules;

  @override
  void paint(Canvas canvas, Size size) {
    final extent = modules.fold<int>(
      0,
      (n, p) => [n, p.$1 + 1, p.$2 + 1].reduce((a, b) => a > b ? a : b),
    );
    final cell = (size.shortestSide / (extent + 8)).floorToDouble();
    final origin = (size.shortestSide - extent * cell) / 2;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final ink = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (final (x, y) in modules) {
      canvas.drawRect(
        Rect.fromLTWH(origin + x * cell, origin + y * cell, cell, cell),
        ink,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _InviteQr oldDelegate) =>
      oldDelegate.modules != modules;
}

class _AcceptInviteDialog extends StatefulWidget {
  const _AcceptInviteDialog();

  @override
  State<_AcceptInviteDialog> createState() => _AcceptInviteDialogState();
}

class _AcceptInviteDialogState extends State<_AcceptInviteDialog> {
  final _input = TextEditingController();
  bool _scanning = false;
  bool _cameraPermissionNeeded = false;
  String? _scanError;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanError = null;
      _cameraPermissionNeeded = false;
    });
    try {
      final value = await const MethodChannel('io.zompado.host')
          .invokeMethod<String>('scanFriendInvite');
      if (!mounted || value == null) return;
      if (value.isEmpty || value.length > 4096) {
        setState(
          () =>
              _scanError = 'Scan the QR code from your friend’s Invite screen.',
        );
        return;
      }
      _input.text = value;
      _accept();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _cameraPermissionNeeded = error.code == 'CAMERA_PERMISSION';
          _scanError = switch (error.code) {
            'CAMERA_PERMISSION' =>
              'Allow camera access to scan a QR code, or paste an invite link.',
            'CAMERA_UNAVAILABLE' =>
              'This device has no camera. Paste your friend’s invite link.',
            _ => 'Couldn’t open the camera. Try again or paste an invite link.',
          };
        });
      }
    } on MissingPluginException {
      if (mounted)
        setState(
          () => _scanError =
              'Scanner unavailable. Paste a friend invite link here.',
        );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _openCameraSettings() async {
    try {
      await const MethodChannel('io.zompado.host')
          .invokeMethod<void>('openCameraSettings');
    } on PlatformException {
      if (mounted) {
        setState(
          () => _scanError = 'Open Settings → Setup to allow camera access.',
        );
      }
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _accept() {
    final invite = _input.text.trim();
    if (invite.isNotEmpty) Navigator.pop(context, invite);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Accept invite'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _scanning ? null : _scan,
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(_scanning ? 'Opening scanner…' : 'Scan QR code'),
        ),
        if (_cameraPermissionNeeded)
          TextButton(
            onPressed: _openCameraSettings,
            child: const Text('Open camera settings'),
          ),
        if (_scanError case final error?) Text(error),
        const SizedBox(height: 12),
        TextField(
          enabled: !_scanning,
          controller: _input,
          maxLength: 4096,
          decoration: const InputDecoration(labelText: 'Paste invite link'),
          onSubmitted: (_) => _accept(),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: _scanning
            ? null
            : () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                final value = data?.text;
                if (mounted && value != null && value.length <= 4096)
                  _input.text = value;
              },
        child: const Text('Paste'),
      ),
      FilledButton(
        onPressed: _scanning ? null : _accept,
        child: const Text('Accept'),
      ),
    ],
  );
}

class FriendConversation extends StatefulWidget {
  const FriendConversation({
    super.key,
    required this.chatmail,
    required this.id,
    required this.initialName,
    required this.pickGameLink,
    required this.openGameLink,
    required this.prepareGame,
  }) : onClose = null;

  const FriendConversation.docked({
    super.key,
    required this.chatmail,
    required this.id,
    required VoidCallback this.onClose,
  }) : initialName = 'Match chat',
       pickGameLink = null,
       openGameLink = null,
       prepareGame = null;

  final Chatmail chatmail;
  final int id;
  final VoidCallback? onClose;
  final String initialName;
  final Future<String?> Function()? pickGameLink;
  final Future<void> Function(GameLink)? openGameLink;
  final Future<GameRelease?> Function(GameLink)? prepareGame;

  @override
  State<FriendConversation> createState() => _FriendConversationState();
}

class _FriendConversationState extends State<FriendConversation>
    with WidgetsBindingObserver {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  bool _awayFromLatest = false;
  ChatFile? _attachment;
  FriendThread? _thread;
  StreamSubscription<void>? _events;
  Timer? _timer;
  bool _fetching = false;
  bool _fetchAgain = false;
  bool _sending = false;
  bool _pickingGame = false;
  int _limit = 60;
  String? _loadError;
  String? _sendError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateScroll);
    WidgetsBinding.instance.addObserver(this);
    _events = widget.chatmail.changes.listen((_) {
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 220), _load);
    });
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _events?.cancel();
    _composer.dispose();
    _scroll.dispose();
    if (!_sending) _attachment?.discard();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (_fetching) {
      _fetchAgain = true;
      return;
    }
    _fetching = true;
    try {
      final thread = await widget.chatmail.thread(widget.id, limit: _limit);
      if (!mounted) return;
      setState(() {
        _thread = thread;
        _loadError = null;
      });
      if (ModalRoute.of(context)?.isCurrent == true &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        await widget.chatmail.markSeen([
          for (final message in thread.messages)
            if (!message.outgoing &&
                message.state == 10 &&
                (widget.onClose == null ||
                    !message.encrypted ||
                    MatchEvent.parse(message.text) == null))
              message.id,
        ]);
      }
    } catch (error) {
      if (mounted) setState(() => _loadError = _failure(error));
    } finally {
      _fetching = false;
      if (_fetchAgain) {
        _fetchAgain = false;
        unawaited(_load());
      }
    }
  }

  void _updateScroll() {
    if (!_scroll.hasClients) return;
    final away = _scroll.offset > 80;
    if (away != _awayFromLatest) setState(() => _awayFromLatest = away);
  }

  void _latest() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _showEmoji() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => ChatEmojiPicker(
        draft: _composer,
        insert: (value) {
          final current = _composer.value;
          final selection = current.selection;
          final start = selection.isValid
              ? selection.start
              : current.text.length;
          final end = selection.isValid ? selection.end : start;
          final text = current.text.replaceRange(start, end, value);
          if (text.length > 5000) return;
          _composer.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: start + value.length),
          );
        },
      ),
    );
  }

  final _updatingMessages = <int>{};

  Future<void> _updateMessage(
    FriendMessage message,
    Future<void> Function() update,
  ) async {
    if (!_updatingMessages.add(message.id)) return;
    try {
      await update();
      await _load();
    } catch (error) {
      if (mounted) setState(() => _sendError = _failure(error));
    } finally {
      _updatingMessages.remove(message.id);
    }
  }

  Future<void> _chooseReaction(FriendMessage message) async {
    FocusManager.instance.primaryFocus?.unfocus();
    String? chosen;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) =>
          ChatEmojiPicker(single: true, insert: (emoji) => chosen = emoji),
    );
    if (!mounted || chosen == null) return;
    final repeat = message.reactions.any(
      (reaction) => reaction.mine && reaction.emoji == chosen,
    );
    await _updateMessage(
      message,
      () => widget.chatmail.react(message.id, repeat ? null : chosen),
    );
  }

  Widget _messageHeader(
    BuildContext context,
    FriendMessage message,
    String peer,
    bool canSend,
  ) {
    final name = message.sender?.name.trim();
    final author = name == null || name.isEmpty
        ? (message.outgoing ? 'You' : peer)
        : name;
    final theme = Theme.of(context);
    final time = chatTime(context, message.timestamp);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          ChatAvatar(author, photo: message.sender?.photo, radius: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  author,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (time.isNotEmpty)
                  Text(
                    time,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'React to message',
            onPressed: canSend ? () => _chooseReaction(message) : null,
            iconSize: 19,
            color: theme.colorScheme.onSurfaceVariant,
            icon: const Icon(Icons.add_reaction_outlined),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: message.savedId == null
                ? 'Save message'
                : 'Unsave message',
            onPressed: () => _updateMessage(
              message,
              () => widget.chatmail.toggleSaved(message),
            ),
            iconSize: 20,
            icon: Icon(
              message.savedId == null ? Icons.star_border : Icons.star,
              color: message.savedId == null
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _reactions(FriendMessage message, bool canSend) {
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        spacing: 5,
        children: [
          for (final reaction in message.reactions)
            ActionChip(
              label: Text(
                reaction.count == 1
                    ? reaction.emoji
                    : '${reaction.emoji} ${reaction.count}',
              ),
              backgroundColor: reaction.mine
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              onPressed: canSend
                  ? () => _updateMessage(
                      message,
                      () => widget.chatmail.react(
                        message.id,
                        reaction.mine ? null : reaction.emoji,
                      ),
                    )
                  : null,
            ),
        ],
      ),
    );
  }

  Future<void> _chooseAttachment() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Add attachment')),
            for (final (label, icon, value) in const [
              ('Take photo', Icons.photo_camera_outlined, 'capture-photo'),
              ('Record video', Icons.videocam_outlined, 'capture-video'),
              ('Record audio', Icons.mic_none, 'capture-audio'),
              ('Attach File', Icons.attach_file, '*/*'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(sheet, value),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.file_present_outlined),
              title: const Text('Attach Original File'),
              subtitle: const Text(
                'Keeps the original quality and may use more data.',
              ),
              textColor: Theme.of(sheet).colorScheme.onSurfaceVariant,
              iconColor: Theme.of(sheet).colorScheme.onSurfaceVariant,
              onTap: () => Navigator.pop(sheet, 'original'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      if (choice == 'capture-photo' || choice == 'capture-video') {
        final granted = await const MethodChannel('io.zompado.host')
            .invokeMethod<bool>('requestCallCamera');
        if (granted != true) {
          if (mounted)
            setState(
              () => _sendError = 'Allow camera access in Setup to take a photo or record a video.',
            );
          return;
        }
      }
      if (!mounted) return;
      final file = choice == 'capture-audio'
          ? await ChatFile.record(context)
          : await ChatFile.pick(
              choice == 'original' ? '*/*' : choice,
              original: choice == 'original',
            );
      if (file == null) return;
      if (!mounted) {
        await file.discard();
        return;
      }
      final prior = _attachment;
      setState(() {
        _attachment = file;
        _sendError = null;
      });
      await prior?.discard();
    } catch (_) {
      if (mounted) setState(() => _sendError = 'Couldn’t add that attachment.');
    }
  }

  Future<bool> _send({String? gameLink}) async {
    final original = _composer.text;
    final text = gameLink ?? original.trim();
    final attachment = gameLink == null ? _attachment : null;
    if (_sending ||
        (text.isEmpty && attachment == null) ||
        _thread?.canSend != true)
      return false;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    ChatFile? prepared;
    try {
      if (attachment != null &&
          !attachment.original &&
          !attachment.voice &&
          (attachment.mediaType == 'Audio' ||
              attachment.mediaType == 'Video')) {
        prepared = await attachment.prepare(await widget.chatmail.dataSaver());
      }
      if (!mounted) {
        await attachment?.discard();
        return false;
      }
      final outgoing = prepared ?? attachment;
      await widget.chatmail.send(
        widget.id,
        text,
        file: outgoing?.path,
        filename: outgoing?.name,
        mediaType: outgoing?.mediaType,
      );
      await attachment?.discard();
      if (!mounted) return false;
      if (attachment != null) setState(() => _attachment = null);
      if (gameLink == null && _composer.text == original) _composer.clear();
      await _load();
      if (mounted) _latest();
      return true;
    } catch (error) {
      if (mounted)
        setState(
          () => _sendError = error is TimeoutException
              ? 'The send timed out. Check the conversation before sending again.'
              : _failure(error),
        );
      if (error is TimeoutException) await _load();
      if (!mounted) await attachment?.discard();
      return false;
    } finally {
      await prepared?.discard();
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _inviteMatch() async {
    if (_pickingGame || _sending || _thread?.canSend != true) return;
    setState(() => _pickingGame = true);
    try {
      final link = await widget.pickGameLink!();
      if (!mounted || link == null) return;
      final game = GameLink.parse(link);
      if (game == null) return;
      final action = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Invite to Cats vs Dogs?'),
          content: const Text(
            'Your friend can accept the invite in this chat. You take the first turn.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, 'share'),
              child: const Text('Share game link'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, 'invite'),
              child: const Text('Send match invite'),
            ),
          ],
        ),
      );
      if (!mounted || action == null) return;
      if (action == 'share') {
        await _send(gameLink: link);
      } else {
        final invite = MatchEvent.invite(game);
        if (await _send(gameLink: invite.wire) && mounted) {
          _openMatch(invite.id);
        }
      }
    } finally {
      if (mounted) setState(() => _pickingGame = false);
    }
  }

  void _openMatch(String id, {bool accept = false, bool play = false}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => OnlineMatchPage(
            chatmail: widget.chatmail,
            chat: widget.id,
            id: id,
            acceptOnOpen: accept,
            playOnOpen: play,
            prepareGame: widget.prepareGame!,
            friendName: _thread?.name ?? widget.initialName,
            buildChatDock: (close) => FriendConversation.docked(
              chatmail: widget.chatmail,
              id: widget.id,
              onClose: close,
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final thread = _thread;
    final visible =
        thread?.messages.where((message) {
          if (!message.outgoing && !message.encrypted) return true;
          final event = MatchEvent.parse(message.text);
          return event == null ||
              (event.kind == 'invite' && widget.onClose == null);
        }).toList() ??
        const <FriendMessage>[];
    final colors = Theme.of(context).colorScheme;
    final messageTextSize =
        ChatChrome.of(context)?.messageTextSize ?? defaultMessageTextSize;
    final history = <String, List<FriendMessage>>{};
    for (final message in thread?.messages ?? const <FriendMessage>[]) {
      if (MatchEvent.parse(message.text) case final event?) {
        (history[event.id] ??= []).add(message);
      }
    }
    final docked = widget.onClose != null;
    final voice = VoiceScope.of(context);
    final appBar = AppBar(
      automaticallyImplyLeading: !docked,
      primary: !docked,
      title: Text(thread?.name ?? widget.initialName),
      actions: [
        if (!docked && voice != null)
          IconButton(
            tooltip: 'Voice call',
            icon: const Icon(Icons.call_outlined),
            onPressed: voice.busy || thread?.canSend != true
                ? null
                : () => voice.dial(widget.id, thread!.name),
          ),
        if (!docked) ...chatActions(context),
      ],
    );
    final body = SafeArea(
      top: false,
      child: Column(
        children: [
          if (_loadError case final error?)
            ListTile(
              title: Text(error),
              trailing: TextButton(
                onPressed: _load,
                child: const Text('Retry'),
              ),
            ),
          if (thread == null)
            if (_loadError == null) const LinearProgressIndicator(),
          if (thread != null && !thread.canSend)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'Connecting with your friend. This chat will open for messages once it is ready.',
              ),
            ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                thread == null || (visible.isEmpty && !thread.hasOlder)
                    ? Center(
                        child: Text(
                          thread?.canSend == true
                              ? 'Send your first message.'
                              : '',
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 60),
                        itemCount: visible.length + (thread.hasOlder ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == visible.length) {
                            return TextButton(
                              onPressed: () {
                                _limit += 60;
                                _load();
                              },
                              child: const Text('Load older messages'),
                            );
                          }
                          final message = visible[visible.length - index - 1];
                          final text = message.text.isEmpty
                              ? 'Attachment'
                              : message.text;
                          if (message.info) {
                            return Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(text, textAlign: TextAlign.center),
                            );
                          }
                          final match = (message.outgoing || message.encrypted)
                              ? MatchEvent.parse(message.text)
                              : null;
                          final gameLink = GameLink.parse(message.text);
                          final invitation = match?.kind == 'invite'
                              ? OnlineMatch.replay(
                                  match!.id,
                                  history[match.id]!,
                                )
                              : null;
                          return Align(
                            alignment: message.outgoing
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onLongPress: () => showMessageActions(
                                context,
                                widget.chatmail,
                                message,
                              ),
                              child: Container(
                                margin: EdgeInsets.only(
                                  bottom: 14,
                                  left: message.outgoing ? 32 : 0,
                                  right: message.outgoing ? 0 : 32,
                                ),
                                constraints: const BoxConstraints(
                                  maxWidth: 350,
                                  minWidth: 210,
                                ),
                                child: MessageBubble(
                                  outgoing: message.outgoing,
                                  builder: (bubble) {
                                    final bubbleColors = Theme.of(bubble)
                                        .colorScheme;
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _messageHeader(
                                          bubble,
                                          message,
                                          thread.name,
                                          thread.canSend,
                                        ),
                                        if (invitation != null) ...[
                                          MessageBody(
                                            message.outgoing
                                                ? 'You invited ${thread.name} to play Cats vs Dogs.'
                                                : '${thread.name} invited you to play Cats vs Dogs.',
                                            size: messageTextSize,
                                          ),
                                          if (!message.outgoing &&
                                              !invitation.accepted &&
                                              !invitation.finished)
                                            Wrap(
                                              spacing: 8,
                                              children: [
                                                TextButton(
                                                  style: TextButton.styleFrom(
                                                    foregroundColor:
                                                        bubbleColors.error,
                                                  ),
                                                  onPressed: _sending
                                                      ? null
                                                      : () => _send(
                                                          gameLink: invitation
                                                              .invite
                                                              .decline()
                                                              .wire,
                                                        ),
                                                  child: const Text('Decline'),
                                                ),
                                                FilledButton(
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor:
                                                        const Color(0xff1b663c),
                                                    foregroundColor:
                                                        Colors.white,
                                                  ),
                                                  onPressed: _sending
                                                      ? null
                                                      : () => _openMatch(
                                                          invitation.invite.id,
                                                          accept: true,
                                                        ),
                                                  child: const Text('Accept'),
                                                ),
                                              ],
                                            )
                                          else if (!invitation.finished)
                                            TextButton(
                                              onPressed: () => _openMatch(
                                                invitation.invite.id,
                                                play: invitation.started,
                                              ),
                                              child: Text(
                                                invitation.started
                                                    ? 'Resume Game'
                                                    : 'Open Cats vs Dogs match',
                                              ),
                                            )
                                          else
                                            MessageBody(
                                              invitation.status,
                                              size: messageTextSize,
                                            ),
                                        ] else if (gameLink != null &&
                                            widget.openGameLink != null)
                                          OutlinedButton.icon(
                                            onPressed: () =>
                                                widget.openGameLink!(gameLink),
                                            icon: const Icon(
                                              Icons.sports_esports_outlined,
                                            ),
                                            label: Text(
                                              gameLink.id == 'drop-four'
                                                  ? 'Open Cats vs Dogs'
                                                  : 'Open game',
                                            ),
                                          )
                                        else ...[
                                          if (message.file != null)
                                            ChatAttachment(message),
                                          if (message.filename case final name?)
                                            MessageBody(
                                              name,
                                              size: messageTextSize,
                                              bold: true,
                                            ),
                                          if (message.text.isNotEmpty ||
                                              message.filename == null)
                                            ChatText(
                                              text,
                                              size: messageTextSize,
                                            ),
                                        ],
                                        if (message.reactions.isNotEmpty)
                                          _reactions(message, thread.canSend),
                                        if (message.delivery
                                            case final delivery?)
                                          Text(
                                            delivery,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color:
                                                  bubbleColors.onSurfaceVariant,
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                if (_awayFromLatest || (!docked && thread?.canSend == true))
                  Positioned(
                    right: 10,
                    bottom: 7,
                    child: FloatingActionButton.small(
                      heroTag: null,
                      tooltip: _awayFromLatest
                          ? 'Jump to latest message'
                          : 'Invite to a Cats vs Dogs match',
                      onPressed: _awayFromLatest
                          ? _latest
                          : _pickingGame || _sending
                          ? null
                          : _inviteMatch,
                      child: Icon(
                        _awayFromLatest
                            ? Icons.arrow_downward
                            : Icons.sports_esports_outlined,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_sending && _attachment != null) const LinearProgressIndicator(),
          if (_sendError case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(error, style: TextStyle(color: colors.error)),
            ),
          if (_attachment case final file?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: InputChip(
                label: Text(file.name, overflow: TextOverflow.ellipsis),
                onDeleted: _sending
                    ? null
                    : () {
                        setState(() => _attachment = null);
                        unawaited(file.discard());
                      },
              ),
            ),
          if (thread?.canSend == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    tooltip: 'Add attachment',
                    onPressed: _sending ? null : _chooseAttachment,
                    icon: const Icon(Icons.attach_file),
                  ),
                  IconButton(
                    tooltip: 'Emoji',
                    onPressed: _sending ? null : _showEmoji,
                    icon: const Icon(Icons.emoji_emotions_outlined),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      maxLength: 5000,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Write a message',
                        counterText: '',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Send message',
                    onPressed: _sending || _pickingGame ? null : () => _send(),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (!docked) return Scaffold(appBar: appBar, body: body);
    return Material(
      elevation: 12,
      child: Column(
        children: [
          appBar,
          Expanded(child: body),
        ],
      ),
    );
  }
}
