import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chatmail.dart';
import 'chat_files.dart';
import 'chat_gallery.dart';
import 'chat_search.dart';
import 'tab_content.dart';
import 'chat_emoji.dart';
import 'chat_avatar.dart';
import 'chat_chrome.dart';
import 'dialog_actions.dart';
import 'message_bubble.dart';
import 'chat_preview.dart';
import 'game_link.dart';
import 'game_invite_picker.dart';
import 'github_distribution.dart';
import 'online_match.dart';
import 'online_match_page.dart';
import 'saved_messages.dart';
import 'voice_calls.dart';

String _failure(Object error) => switch (error) {
  MatchInviteExpired() => MatchInviteExpired.message,
  ChatmailIssue.invite =>
    'Use a link from your friend’s Share my invite screen.',
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
    this.active = true,
    required this.pins,
    required this.savePins,
    required this.addContact,
    required this.installedGames,
    required this.verifiedGameLink,
    required this.openGameLink,
    required this.prepareGame,
  });

  final Chatmail chatmail;
  final bool active;
  final Set<int> pins;
  final ValueChanged<Set<int>> savePins;
  final Future<void> Function(BuildContext) addContact;
  final List<GameRelease> Function() installedGames;
  final Future<String?> Function(GameRelease) verifiedGameLink;
  final Future<void> Function(GameLink) openGameLink;
  final Future<GameRelease?> Function(GameLink) prepareGame;

  @override
  State<FriendsPane> createState() => _FriendsPaneState();
}

enum _ChatFolder { inbox, archive, trash }

class _FriendsPaneState extends State<FriendsPane> {
  final _name = TextEditingController();
  final _search = TextEditingController();
  late final _pins = {...widget.pins};
  final _muting = <int>{};
  List<FriendChat> _chats = [];
  StreamSubscription<void>? _events;
  Timer? _refreshTimer;
  bool _ready = false;
  _ChatFolder _folder = _ChatFolder.inbox;
  bool _busy = true;
  bool _refreshing = false;
  bool _refreshQueued = false;
  bool _loadingFolder = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _events = widget.chatmail.changes.listen((_) {
      if (!widget.active) return;
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
  void didUpdateWidget(FriendsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) _refreshTimer?.cancel();
    if (!oldWidget.active && widget.active) {
      if (_ready) {
        unawaited(_refresh());
      } else if (!_busy) {
        unawaited(_initialize());
      }
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _events?.cancel();
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _initialize() => _perform(() async {
    _ready = await widget.chatmail.restore();
    if (_ready) {
      _chats = await _loadFolder(_folder);
      _loadingFolder = false;
    }
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
    final folder = _folder;
    try {
      final chats = await _loadFolder(folder);
      if (mounted && folder == _folder)
        setState(() {
          _chats = chats;
          _loadingFolder = false;
          if (!_busy) _error = null;
        });
    } catch (error) {
      if (mounted && folder == _folder) {
        setState(() {
          _loadingFolder = false;
          if (!_busy) _error = _failure(error);
        });
      }
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
          installedGames: widget.installedGames,
          verifiedGameLink: widget.verifiedGameLink,
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
    FocusScope.of(context).unfocus();
    setState(() {
      _folder = folder;
      _chats = [];
      _loadingFolder = true;
      _error = null;
    });
    unawaited(_refresh());
  }

  Future<void> _emptyTrash() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: const Text('Empty trash?'),
        content: const Text('This permanently deletes all chats in Trash.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructiveDialogAction(dialog),
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
          scrollable: true,
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

  Future<void> _toggleMute(FriendChat chat) async {
    if (_muting.contains(chat.id)) return;
    setState(() => _muting.add(chat.id));
    try {
      final muted = !chat.muted;
      await widget.chatmail.manageChat(chat.id, muted ? 'mute' : 'unmute');
      if (!mounted) return;
      await _refresh();
      if (!mounted || !widget.active) return;
      unawaited(
        showNotificationFeedback(
          context,
          muted ? 'Chat notifications muted' : 'Chat notifications on',
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t change chat notifications.')),
        );
      }
    } finally {
      if (mounted) setState(() => _muting.remove(chat.id));
    }
  }

  void _togglePin(int chat) {
    setState(() {
      if (!_pins.add(chat)) _pins.remove(chat);
    });
    widget.savePins(_pins);
  }

  Widget _chatRow(FriendChat chat, String preview) {
    final colors = Theme.of(context).colorScheme;
    final trashed = _folder == _ChatFolder.trash;
    final pinned = _pins.contains(chat.id);
    final avatar = ChatAvatar(chat.name, photo: chat.photo);
    return Card(
      key: ValueKey(chat.id),
      child: LayoutBuilder(
        builder: (context, box) {
          final actions = trashed
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: chat.muted ? 'Unmute chat' : 'Mute chat',
                      icon: Icon(
                        chat.muted
                            ? Icons.notifications_off_outlined
                            : Icons.notifications_none,
                      ),
                      color: chat.muted
                          ? colors.onSurfaceVariant.withValues(alpha: .62)
                          : colors.onSurface,
                      onPressed: _busy || _muting.contains(chat.id)
                          ? null
                          : () => _toggleMute(chat),
                    ),
                    IconButton(
                      tooltip: pinned ? 'Unpin chat' : 'Pin chat',
                      icon: Icon(
                        pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      ),
                      color: pinned ? colors.primary : null,
                      onPressed: _busy ? null : () => _togglePin(chat.id),
                    ),
                  ],
                );
          final stackActions = actions != null && box.maxWidth < 235;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ListTile(
                contentPadding: const EdgeInsetsDirectional.fromSTEB(
                  12,
                  0,
                  6,
                  0,
                ),
                horizontalTitleGap: 10,
                leading: chat.unread > 0
                    ? Semantics(
                        label: '${chat.unread} unread messages',
                        child: Badge.count(count: chat.unread, child: avatar),
                      )
                    : avatar,
                title: Text(
                  chat.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: preview.isEmpty
                    ? null
                    : Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: stackActions ? null : actions,
                onTap: _busy
                    ? null
                    : trashed
                    ? () => _chatMenu(chat)
                    : () => _open(chat.id, chat.name),
                onLongPress: _busy ? null : () => _chatMenu(chat),
              ),
              if (stackActions) actions,
            ],
          );
        },
      ),
    );
  }

  String _preview(FriendChat chat) =>
      chat.preview.startsWith(matchMarker.trimRight())
      ? 'Cats vs Dogs match update'
      : chat.preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final matches = _chats.where(
      (chat) =>
          chat.name.toLowerCase().contains(query) ||
          _preview(chat).toLowerCase().contains(query),
    );
    final visible = [
      if (_folder != _ChatFolder.trash)
        ...matches.where((chat) => _pins.contains(chat.id)),
      ...matches.where(
        (chat) => _folder == _ChatFolder.trash || !_pins.contains(chat.id),
      ),
    ];
    final body = ListView(
      key: PageStorageKey(_folder),
      primary: false,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(20, _ready ? 0 : 10, 20, 24),
      children: [
        if (!_ready) ...[
          if (_busy) const LinearProgressIndicator(),
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
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child: ChatSearchField(
              label: 'Search chats',
              controller: _search,
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (_folder == _ChatFolder.trash)
            Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: theme.brightness == Brightness.dark
                            ? Colors.greenAccent.shade100
                            : Colors.green.shade800,
                      ),
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
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      onPressed: _busy || _chats.isEmpty ? null : _emptyTrash,
                      child: const Text(
                        'Empty trash',
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 14),
          if (_busy || _loadingFolder) const LinearProgressIndicator(),
          if (visible.isEmpty && !_busy && !_loadingFolder && _error == null)
            if (query.isNotEmpty)
              const Text('No matching chats.')
            else if (_folder == _ChatFolder.inbox)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 28, 0, 16),
                child: Column(
                  children: [
                    Icon(
                      Icons.person_add_alt_outlined,
                      size: 40,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text('No chats yet', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text(
                      'Connect with a friend to start chatting.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () async {
                        await widget.addContact(context);
                        if (mounted) await _refresh();
                      },
                      child: const Text('Add a contact'),
                    ),
                  ],
                ),
              )
            else
              Text(
                _folder == _ChatFolder.archive
                    ? 'No archived chats.'
                    : 'Trash is empty.',
              ),
          for (final chat in visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _chatRow(chat, _preview(chat)),
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
    if (!_ready) return body;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<_ChatFolder>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _ChatFolder.inbox, label: Text('Inbox')),
                ButtonSegment(
                  value: _ChatFolder.archive,
                  label: Text('Archive'),
                ),
                ButtonSegment(value: _ChatFolder.trash, label: Text('Trash')),
              ],
              selected: {_folder},
              onSelectionChanged: _busy
                  ? null
                  : (folders) => _selectFolder(folders.single),
            ),
          ),
        ),
        Expanded(
          child: TabContent(selection: _folder, child: body),
        ),
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

  Future<void> choose() async {
    final shareMine = await showDialog<bool>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('Add a contact'),
        children: [
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('Share my invite'),
            subtitle: const Text('Send your link or show your QR code.'),
            onTap: () => Navigator.pop(dialog, true),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('Accept an invite'),
            subtitle: const Text('Scan a QR code or paste a link.'),
            onTap: () => Navigator.pop(dialog, false),
          ),
        ],
      ),
    );
    if (!context.mounted || shareMine == null) return;
    if (shareMine) {
      await create();
    } else {
      await accept();
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
        title: const Text('Share my invite'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (modules.isNotEmpty)
              Semantics(
                label: 'Friend invite QR code',
                image: true,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: CustomPaint(painter: _InviteQr(modules)),
                  ),
                ),
              ),
            if (modules.isNotEmpty) const SizedBox(height: 16),
            Text(
              modules.isEmpty
                  ? 'Share the link so your friend can use Accept an invite.'
                  : 'Have your friend scan this code, or share the invite link.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: invite));
                    if (!dialog.mounted) return;
                    Navigator.pop(dialog);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invite copied.')),
                    );
                  },
                  child: const Text('Copy link'),
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
                            content: Text(
                              'Sharing is unavailable. Use Copy link.',
                            ),
                          ),
                        );
                    }
                  },
                  child: const Text('Share'),
                ),
              ],
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  });

  Future<void> accept() async {
    final chat = await showDialog<int>(
      context: context,
      builder: (_) => fitDialogToKeyboard(
        _AcceptInviteDialog(acceptInvite: chatmail.acceptInvite),
      ),
    );
    if (context.mounted && chat != null) {
      await _perform(() => open(chat, 'Friend'));
    }
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
  const _AcceptInviteDialog({required this.acceptInvite});

  final Future<int> Function(String) acceptInvite;

  @override
  State<_AcceptInviteDialog> createState() => _AcceptInviteDialogState();
}

class _AcceptInviteDialogState extends State<_AcceptInviteDialog> {
  static const _maxLength = 4096;
  final _input = TextEditingController();
  bool _scanning = false, _accepting = false;
  String? _linkError;
  bool _cameraPermissionNeeded = false;
  String? _scanError;

  Future<void> _scan() async {
    if (_scanning || _accepting) return;
    String? value;
    setState(() {
      _scanning = true;
      _scanError = null;
      _cameraPermissionNeeded = false;
    });
    try {
      value = await const MethodChannel('io.zompado.host')
          .invokeMethod<String>('scanFriendInvite');
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
    if (!mounted || value == null) return;
    final invite = value.trim();
    if (invite.isEmpty || invite.length > _maxLength) {
      setState(
        () => _scanError =
            'Scan the QR code from your friend’s Share my invite screen.',
      );
      return;
    }
    _input.text = invite;
    await _accept();
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

  Future<void> _paste() async {
    try {
      final text = await readPastedLink(_maxLength);
      if (!mounted || _scanning || _accepting) return;
      _input.text = text;
      setState(() => _linkError = null);
    } on FormatException catch (error) {
      if (mounted && !_scanning && !_accepting) {
        setState(() => _linkError = error.message);
      }
    }
  }

  Future<void> _accept() async {
    final invite = _input.text.trim();
    if (_scanning || _accepting || invite.isEmpty) return;
    setState(() {
      _accepting = true;
      _linkError = null;
    });
    try {
      final chat = await widget.acceptInvite(invite);
      if (mounted) Navigator.pop(context, chat);
    } catch (error) {
      if (mounted) setState(() => _linkError = _failure(error));
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_accepting,
    child: AlertDialog(
      title: const Text('Accept an invite'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed: _scanning || _accepting ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(_scanning ? 'Opening scanner…' : 'Scan QR code'),
          ),
          if (_cameraPermissionNeeded)
            TextButton(
              onPressed: _accepting ? null : _openCameraSettings,
              child: const Text('Open camera settings'),
            ),
          if (_scanError case final error?)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 16),
          TextField(
            enabled: !_scanning && !_accepting,
            controller: _input,
            maxLength: _maxLength,
            decoration: InputDecoration(
              labelText: 'Invite link',
              hintText: 'Paste your friend’s link',
              border: const OutlineInputBorder(),
              counterText: '',
              errorText: _linkError,
              errorMaxLines: 4,
            ),
            onChanged: (_) {
              if (_linkError != null) setState(() => _linkError = null);
            },
            onSubmitted: (_) => _accept(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _accepting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _scanning || _accepting ? null : _paste,
          child: const Text('Paste'),
        ),
        ValueListenableBuilder(
          valueListenable: _input,
          builder: (context, input, _) => FilledButton(
            onPressed: _scanning || _accepting || input.text.trim().isEmpty
                ? null
                : _accept,
            child: Text(_accepting ? 'Accepting…' : 'Accept'),
          ),
        ),
      ],
    ),
  );
}

class FriendConversation extends StatefulWidget {
  const FriendConversation({
    super.key,
    required this.chatmail,
    required this.id,
    required this.initialName,
    required this.installedGames,
    required this.verifiedGameLink,
    required this.openGameLink,
    required this.prepareGame,
  }) : onClose = null;

  const FriendConversation.docked({
    super.key,
    required this.chatmail,
    required this.id,
    required VoidCallback this.onClose,
  }) : initialName = 'Match chat',
       installedGames = null,
       verifiedGameLink = null,
       openGameLink = null,
       prepareGame = null;

  final Chatmail chatmail;
  final int id;
  final VoidCallback? onClose;
  final String initialName;
  final List<GameRelease> Function()? installedGames;
  final Future<String?> Function(GameRelease)? verifiedGameLink;
  final Future<void> Function(GameLink)? openGameLink;
  final Future<GameRelease?> Function(GameLink)? prepareGame;

  @override
  State<FriendConversation> createState() => _FriendConversationState();
}

class _FriendConversationState extends State<FriendConversation>
    with WidgetsBindingObserver {
  final _composer = TextEditingController();
  final _conversationSearch = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  bool _awayFromLatest = false;
  bool _showMedia = false;
  bool _openedMedia = false;
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
    _conversationSearch.dispose();
    _searchFocus.dispose();
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
      if (!_showMedia &&
          ModalRoute.of(context)?.isCurrent == true &&
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
      isScrollControlled: true,
      useSafeArea: true,
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
      isScrollControlled: true,
      useSafeArea: true,
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
    final time = chatTime(
      context,
      message.timestamp,
      compact: true,
      showYear: false,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          ChatAvatar(
            author,
            photo: message.sender?.photo,
            radius: 16,
            backgroundColor: theme.colorScheme.onSecondaryContainer,
            foregroundColor: theme.colorScheme.secondaryContainer,
          ),
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
            iconSize: 23,
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
            iconSize: 24,
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

  Widget _reactions(BuildContext context, FriendMessage message, bool canSend) {
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        spacing: 5,
        children: [
          for (final reaction in message.reactions)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                  disabledForegroundColor: Theme.of(context)
                      .colorScheme
                      .onSurface,
                  minimumSize: const Size(44, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: canSend && !reaction.mine
                    ? () => _updateMessage(
                        message,
                        () => widget.chatmail.react(message.id, reaction.emoji),
                      )
                    : null,
                child: Text(
                  reaction.count == 1
                      ? reaction.emoji
                      : '${reaction.emoji} ${reaction.count}',
                ),
              ),
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
      final event = gameLink == null ? null : MatchEvent.parse(gameLink);
      if (event?.kind == 'invite') {
        final moved = await widget.chatmail.sendMatchOpening(widget.id, event!);
        if (mounted && moved != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(matchMovedNotice(moved))));
        }
      } else {
        await widget.chatmail.send(
          widget.id,
          text,
          file: outgoing?.path,
          filename: outgoing?.name,
          mediaType: outgoing?.mediaType,
        );
      }
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
    final friend = _thread!.name;
    setState(() => _pickingGame = true);
    try {
      FocusScope.of(context).unfocus();
      final selected = await showGameInvitePicker<GameRelease>(
        context,
        title: 'Choose a game',
        detail: 'Play with $friend',
        emptyMessage:
            'Install an online game from Get Games to invite a friend.',
        options: [
          for (final game in widget.installedGames!())
            (
              value: game,
              label: game.title,
              leading: gameInviteArtwork(game),
              unavailable: MatchEvent.supportsGame(game)
                  ? null
                  : 'Online play unavailable',
            ),
        ],
      );
      if (!mounted || selected == null) return;
      final link = await widget.verifiedGameLink!(selected);
      if (!mounted || link == null) return;
      final game = GameLink.parse(link);
      if (game == null || _thread?.canSend != true) return;
      final invite = MatchEvent.invite(game);
      if (await _send(gameLink: invite.wire) && mounted) {
        _openMatch(invite.id);
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
    final name = thread?.name ?? widget.initialName;
    final query = _conversationSearch.text.trim();
    final search = Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: ChatSearchField(
        label: _showMedia ? 'Search media' : 'Search messages',
        controller: _conversationSearch,
        focusNode: _searchFocus,
        onChanged: (_) => setState(() {}),
      ),
    );
    final appBar = docked
        ? AppBar(
            automaticallyImplyLeading: false,
            primary: false,
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          )
        : chatPageBar(
            context,
            name,
            fitTitle: false,
            firstActions: [
              if (voice != null)
                IconButton(
                  tooltip: 'Voice call',
                  icon: const Icon(Icons.call_outlined),
                  onPressed: voice.busy || thread?.canSend != true
                      ? null
                      : () => voice.openDialer(
                          context,
                          widget.id,
                          thread!.name,
                          photo: thread.photo,
                        ),
                ),
            ],
          );
    final composerFontSize =
        Theme.of(context).textTheme.bodyLarge?.fontSize ?? 16.0;
    final composerLineHeight =
        MediaQuery.textScalerOf(context).scale(composerFontSize) * 1.4;
    Widget content(double availableHeight) {
      // Leave room for the conversation when the keyboard is open.
      final composerLines = ((availableHeight * .6 - 28) / composerLineHeight)
          .floor()
          .clamp(1, 4);
      final canUseGameControl = thread?.canSend == true;
      final compactComposer = availableHeight < 120;
      final showGameControl = _awayFromLatest || (!docked && canUseGameControl);
      final gameControlLabel = _awayFromLatest
          ? 'Jump to latest message'
          : 'Invite to play a game';
      final gameControlIcon = _awayFromLatest
          ? Icons.arrow_downward
          : Icons.sports_esports_outlined;
      final gameControlAction = _awayFromLatest
          ? _latest
          : _pickingGame || _sending
          ? null
          : _inviteMatch;
      return Column(
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
                        key: PageStorageKey('chat-feed-${widget.id}'),
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
                          if (message.info && message.viewType != 'Call') {
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
                                          else if (invitation.active)
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
                                          if (message.bubbleFilename
                                              case final name?)
                                            MessageBody(
                                              name,
                                              size: messageTextSize,
                                              bold: true,
                                            ),
                                          if (message.viewType == 'Call')
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 5,
                                                  ),
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: message.unansweredCall
                                                      ? bubbleColors.error
                                                      : bubbleColors.outline,
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.call_outlined,
                                                    size: 15,
                                                    color:
                                                        message.unansweredCall
                                                        ? bubbleColors.error
                                                        : bubbleColors
                                                              .onSurface,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: MessageBody(
                                                      text,
                                                      size:
                                                          (messageTextSize - 1)
                                                              .clamp(
                                                                12.0,
                                                                maxMessageTextSize,
                                                              ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            )
                                          else if (message.bubbleCaption
                                              .trim()
                                              .isNotEmpty)
                                            ChatText(
                                              message.bubbleCaption,
                                              size: messageTextSize,
                                            )
                                          else if (message.file == null &&
                                              message.bubbleFilename == null)
                                            MessageBody(switch (message.media) {
                                              ChatMedia.image => 'Photo',
                                              ChatMedia.video => 'Video',
                                              ChatMedia.audio => 'Audio',
                                              null => 'Attachment',
                                            }, size: messageTextSize),
                                        ],
                                        if (message.reactions.isNotEmpty)
                                          _reactions(
                                            bubble,
                                            message,
                                            thread.canSend,
                                          ),
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
                if (showGameControl && (!compactComposer || !canUseGameControl))
                  Positioned(
                    right: 10,
                    bottom: 7,
                    width: 48,
                    height: 48,
                    child: FloatingActionButton(
                      heroTag: null,
                      elevation: 5,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: colors.outline),
                      ),
                      tooltip: gameControlLabel,
                      onPressed: gameControlAction,
                      child: Icon(gameControlIcon, size: 26),
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
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      maxLength: 5000,
                      minLines: 1,
                      maxLines: composerLines,
                      decoration: const InputDecoration(
                        hintText: 'Write a message',
                        counterText: '',
                      ),
                    ),
                  ),
                  if (compactComposer && showGameControl)
                    IconButton(
                      tooltip: gameControlLabel,
                      onPressed: gameControlAction,
                      icon: Icon(gameControlIcon, size: 26),
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
      );
    }

    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final body = SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, box) {
          final showTabs =
              !docked && (!keyboardVisible || box.maxHeight >= 160);
          final showSearch =
              !keyboardVisible ||
              _searchFocus.hasFocus ||
              query.isNotEmpty ||
              _showMedia;
          final sideBySide =
              showTabs &&
              showSearch &&
              box.maxHeight < 235 &&
              box.maxWidth >= 320;
          final toolbarWidth = sideBySide ? box.maxWidth / 2 : box.maxWidth;
          return Column(
            children: [
              Flex(
                direction: sideBySide ? Axis.horizontal : Axis.vertical,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showTabs)
                    SizedBox(
                      width: toolbarWidth,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                        child: SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: false, label: Text('Feed')),
                            ButtonSegment(value: true, label: Text('Media')),
                          ],
                          selected: {_showMedia},
                          showSelectedIcon: false,
                          onSelectionChanged: (selected) {
                            FocusScope.of(context).unfocus();
                            final showMedia = selected.single;
                            if (showMedia == _showMedia) return;
                            setState(() {
                              _showMedia = showMedia;
                              _openedMedia = _openedMedia || _showMedia;
                            });
                            if (!showMedia) unawaited(_load());
                          },
                        ),
                      ),
                    ),
                  if (showSearch)
                    SizedBox(
                      key: const ValueKey('conversation-search'),
                      width: toolbarWidth,
                      child: search,
                    ),
                ],
              ),
              Expanded(
                child: TabContent(
                  selection: _showMedia,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_openedMedia)
                        Visibility(
                          visible: _showMedia,
                          maintainState: true,
                          child: ChatGallery(
                            chatmail: widget.chatmail,
                            chat: widget.id,
                            active: _showMedia,
                            query: query,
                          ),
                        ),
                      if (!_showMedia)
                        if (query.isEmpty)
                          LayoutBuilder(
                            builder: (_, feed) => content(feed.maxHeight),
                          )
                        else
                          ConversationSearchResults(
                            chatmail: widget.chatmail,
                            chat: widget.id,
                            name: name,
                            query: query,
                          ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
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
