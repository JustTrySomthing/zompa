import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chatmail.dart';
import 'game_link.dart';
import 'online_match.dart';
import 'online_match_page.dart';

String _failure(Object error) => switch (error) {
  ChatmailIssue.invite => 'Use the invite link from a friend’s Invite screen.',
  ChatmailIssue.encrypted => 'Wait for your friend connection to finish.',
  ChatmailIssue.unavailable =>
    'The Chatmail connection stopped. Retry from Chats.',
  TimeoutException() => 'Chatmail took too long to respond. Try again.',
  _ =>
    'Chatmail couldn’t complete this action. Check your connection and try again.',
};

class FriendsPane extends StatefulWidget {
  const FriendsPane({
    super.key,
    required this.chatmail,
    required this.share,
    required this.pickGameLink,
    required this.openGameLink,
    required this.prepareGame,
  });

  final Chatmail chatmail;
  final Future<void> Function(String) share;
  final Future<String?> Function() pickGameLink;
  final Future<void> Function(GameLink) openGameLink;
  final Future<bool> Function(GameLink) prepareGame;

  @override
  State<FriendsPane> createState() => _FriendsPaneState();
}

class _FriendsPaneState extends State<FriendsPane> {
  final _name = TextEditingController();
  List<FriendChat> _chats = [];
  StreamSubscription<void>? _events;
  Timer? _refreshTimer;
  bool _ready = false;
  bool _busy = true;
  bool _refreshing = false;
  bool _refreshQueued = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _events = widget.chatmail.changes.listen((_) {
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(milliseconds: 220), _refresh);
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
    if (_ready) _chats = await widget.chatmail.chats();
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
      final chats = await widget.chatmail.chats();
      if (mounted)
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
      _chats = await widget.chatmail.chats();
    });
  }

  Future<void> _invite() => _perform(() async {
    final invite = await widget.chatmail.invite();
    List<(int, int)> modules = const [];
    try {
      modules = await widget.chatmail.qrModules(invite);
    } catch (_) {
      // Sharing the original invite link remains available.
    }
    if (!mounted) return;
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
                await widget.share(invite);
              } catch (_) {
                if (mounted)
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

  Future<void> _accept() async {
    final invite = await showDialog<String>(
      context: context,
      builder: (_) => const _AcceptInviteDialog(),
    );
    if (!mounted || invite == null) return;
    await _perform(() async {
      final chat = await widget.chatmail.acceptInvite(invite);
      if (mounted) await _open(chat, 'Friend');
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _invite,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Invite friend'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _accept,
                icon: const Icon(Icons.link),
                label: const Text('Accept invite'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_chats.isEmpty)
            const Text(
              'Your conversations will appear here after you connect with a friend.',
            ),
          for (final chat in _chats)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(chat.name),
                  subtitle: chat.preview.isEmpty
                      ? null
                      : Text(
                          chat.preview.startsWith(matchMarker.trimRight())
                              ? 'Drop Four match update'
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
                  onTap: _busy ? null : () => _open(chat.id, chat.name),
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
  String? _scanError;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanError = null;
    });
    try {
      final value = await const MethodChannel(
        'io.zompado.host',
      ).invokeMethod<String>('scanFriendInvite');
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
    } on PlatformException {
      if (mounted)
        setState(
          () => _scanError =
              'Scanner unavailable. Ask your friend to share the invite link and paste it here.',
        );
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
        if (_scanError case final error?) Text(error),
        const SizedBox(height: 12),
        TextField(
          enabled: !_scanning,
          controller: _input,
          maxLength: 4096,
          decoration: const InputDecoration(labelText: 'Friend invite link'),
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
  final Future<bool> Function(GameLink)? prepareGame;

  @override
  State<FriendConversation> createState() => _FriendConversationState();
}

class _FriendConversationState extends State<FriendConversation>
    with WidgetsBindingObserver {
  final _composer = TextEditingController();
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

  Future<void> _send({String? gameLink}) async {
    final original = _composer.text;
    final text = gameLink ?? original.trim();
    if (_sending || text.isEmpty || _thread?.canSend != true) return;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      await widget.chatmail.send(widget.id, text);
      if (!mounted) return;
      if (gameLink == null && _composer.text == original) _composer.clear();
      await _load();
    } catch (error) {
      if (mounted)
        setState(
          () => _sendError = error is TimeoutException
              ? 'The send timed out. Check the conversation before sending again.'
              : _failure(error),
        );
      if (error is TimeoutException) await _load();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendGame() async {
    setState(() => _pickingGame = true);
    try {
      final link = await widget.pickGameLink!();
      if (!mounted || link == null) return;
      final send = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Share Drop Four?'),
          content: const Text(
            'Your friend will get a game card they can open to install or play Drop Four.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Send game'),
            ),
          ],
        ),
      );
      if (mounted && send == true) await _send(gameLink: link);
    } finally {
      if (mounted) setState(() => _pickingGame = false);
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
      final yes = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Invite to Drop Four?'),
          content: const Text(
            'Your friend can accept the invite in this chat. You take the first turn.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Send match invite'),
            ),
          ],
        ),
      );
      if (mounted && yes == true)
        await _send(gameLink: MatchEvent.invite(game).wire);
    } finally {
      if (mounted) setState(() => _pickingGame = false);
    }
  }

  void _openMatch(String id) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => OnlineMatchPage(
        chatmail: widget.chatmail,
        chat: widget.id,
        id: id,
        prepareGame: widget.prepareGame!,
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
    final docked = widget.onClose != null;
    final appBar = AppBar(
      automaticallyImplyLeading: !docked,
      primary: !docked,
      title: Text(thread?.name ?? widget.initialName),
      actions: [
        if (docked)
          IconButton(
            tooltip: 'Close match chat',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
          )
        else
          IconButton(
            tooltip: 'Invite to a Drop Four match',
            onPressed: _pickingGame || _sending || thread?.canSend != true
                ? null
                : _inviteMatch,
            icon: const Icon(Icons.sports_esports_outlined),
          ),
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
            child: thread == null || (visible.isEmpty && !thread.hasOlder)
                ? Center(
                    child: Text(
                      thread?.canSend == true ? 'Send your first message.' : '',
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
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
                      return Align(
                        alignment: message.outgoing
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 7),
                          constraints: const BoxConstraints(maxWidth: 340),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: message.outgoing
                                ? colors.secondaryContainer
                                : colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (match?.kind == 'invite')
                                OutlinedButton.icon(
                                  onPressed: () => _openMatch(match!.id),
                                  icon: const Icon(
                                    Icons.sports_esports_outlined,
                                  ),
                                  label: const Text('Open Drop Four match'),
                                )
                              else if (gameLink != null &&
                                  widget.openGameLink != null)
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      widget.openGameLink!(gameLink),
                                  icon: const Icon(
                                    Icons.sports_esports_outlined,
                                  ),
                                  label: Text(
                                    gameLink.id == 'drop-four'
                                        ? 'Open Drop Four'
                                        : 'Open game',
                                  ),
                                )
                              else
                                SelectableText(
                                  text,
                                  style: TextStyle(
                                    color: message.outgoing
                                        ? colors.onSecondaryContainer
                                        : colors.onSurface,
                                  ),
                                ),
                              if (message.delivery case final delivery?)
                                Text(
                                  delivery,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSecondaryContainer,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_sendError case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(error, style: TextStyle(color: colors.error)),
            ),
          if (thread?.canSend == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!docked)
                    IconButton(
                      tooltip: 'Share a game',
                      onPressed: _sending || _pickingGame ? null : _sendGame,
                      icon: const Icon(Icons.sports_esports_outlined),
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
