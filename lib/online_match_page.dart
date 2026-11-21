import 'chat_chrome.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import 'chatmail.dart';
import 'game_link.dart';
import 'github_distribution.dart';
import 'online_match.dart';
import 'love_player.dart';
import 'game_toolbar.dart';

class OnlineMatchPage extends StatefulWidget {
  const OnlineMatchPage({
    super.key,
    required this.chatmail,
    required this.chat,
    required this.id,
    required this.prepareGame,
    required this.buildChatDock,
    this.friendName,
    this.acceptOnOpen = false,
    this.playOnOpen = false,
  });

  final Chatmail chatmail;
  final int chat;
  final String id;
  final Future<GameRelease?> Function(GameLink) prepareGame;
  final Widget Function(VoidCallback close) buildChatDock;
  final String? friendName;
  final bool acceptOnOpen, playOnOpen;

  @override
  State<OnlineMatchPage> createState() => _OnlineMatchPageState();
}

class _OnlineMatchPageState extends State<OnlineMatchPage>
    with WidgetsBindingObserver {
  OnlineMatch? _match;
  GameRelease? _game;
  bool _preparing = false;
  bool _acceptedFromChat = false;
  bool _playing = false;
  bool _triedPreparation = false;
  bool _gameUnavailable = false;
  int _boardGeneration = 0;
  StreamSubscription<void>? _events;
  Timer? _timer;
  Timer? _lobbyRefresh;
  Completer<void>? _refreshing;
  bool _again = false, _sending = false;
  String? _error;
  bool _chatOpen = false;
  bool _chatUnread = false;
  StreamSubscription<(int, int)>? _messages;
  Timer? _messageTimer;
  int _latestMessage = 0;
  String? _messagePreview;

  Timer? _turnTimer;
  int? _displayTurn;
  String _myName = 'You';

  Future<void> _loadMyName() async {
    try {
      final name = (await widget.chatmail.profile()).name.trim();
      if (mounted && name.isNotEmpty) setState(() => _myName = name);
    } catch (_) {
      // The turn display can still identify the local player as You.
    }
  }

  void _syncTurn(OnlineMatch? match) {
    if (match == null) return;
    final previous = _match;
    if (previous != null && match.moves.length == previous.moves.length + 1) {
      _turnTimer?.cancel();
      _displayTurn = previous.board.turn;
      _turnTimer = Timer(const Duration(milliseconds: 740), () {
        if (mounted) setState(() => _displayTurn = null);
      });
    } else if (previous?.moves != match.moves) {
      _turnTimer?.cancel();
      _displayTurn = null;
    }
  }

  bool get _boardOpen =>
      _playing && _match != null && _game != null && !_match!.quit;

  void _togglePause(OnlineMatch match) {
    if (_sending ||
        match.finished ||
        (match.pausedByFriend && !match.pausedByMe))
      return;
    final action = match.pausedByMe ? 'resume' : 'pause';
    unawaited(_send(match.invite.control(action, match.nextRevision).wire));
  }

  Future<void> _previewMessage(int chat, int id) async {
    if (chat != widget.chat || !_boardOpen || _chatOpen) return;
    try {
      final target = await widget.chatmail.notificationMessage(chat, id);
      if (!mounted ||
          _chatOpen ||
          !_boardOpen ||
          target == null ||
          id <= _latestMessage)
        return;
      final message = target.message;
      if (message.info ||
          message.viewType == 'Call' ||
          MatchEvent.parse(message.text) != null)
        return;
      final text = message.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      final mime = message.mime ?? '';
      final kind = switch (message.viewType) {
        'Image' || 'Sticker' => 'an image',
        'Gif' => 'a GIF',
        'Video' => 'a video',
        'Audio' || 'Voice' => 'an audio file',
        'Vcard' => 'a contact',
        _ when mime.startsWith('image/') => 'an image',
        _ when mime.startsWith('video/') => 'a video',
        _ when mime.startsWith('audio/') => 'an audio file',
        _
            when message.file != null ||
                message.filename != null ||
                message.viewType == 'File' =>
          'a file',
        _ when GameLink.parse(text) != null => 'a game link',
        _
            when RegExp(
              r'https?://|\bwww\.',
              caseSensitive: false,
            ).hasMatch(text) =>
          'a link',
        _ => null,
      };
      if (kind == null && text.isEmpty) return;
      _latestMessage = id;
      final name = message.sender?.name.trim();
      final sender = name != null && name.isNotEmpty ? name : target.name;
      _messageTimer?.cancel();
      setState(() {
        _messagePreview = kind == null
            ? '$sender: $text'
            : '$sender shared $kind';
      });
      _messageTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _messagePreview = null);
      });
    } catch (_) {
      // A failed preview never interrupts the game.
    }
  }

  void _toggleChat() {
    if (_chatOpen) FocusScope.of(context).unfocus();
    setState(() {
      _chatOpen = !_chatOpen;
      if (_chatOpen) {
        _chatUnread = false;
        _messagePreview = null;
        _messageTimer?.cancel();
      }
    });
    unawaited(_load());
  }

  @override
  void initState() {
    super.initState();
    _playing = widget.playOnOpen;
    unawaited(_loadMyName());
    _messages = widget.chatmail.incoming.listen((event) {
      unawaited(_previewMessage(event.$1, event.$2));
    });
    WidgetsBinding.instance.addObserver(this);
    _events = widget.chatmail.changes.listen((_) {
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 180), _load);
    });
    _lobbyRefresh = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_playing &&
          _match?.finished != true &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_load());
      }
    });
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _lobbyRefresh?.cancel();
    _events?.cancel();
    _messages?.cancel();
    _messageTimer?.cancel();
    _turnTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (_refreshing case final refresh?) {
      _again = true;
      await refresh.future;
      return;
    }
    final refresh = _refreshing = Completer<void>();
    try {
      do {
        _again = false;
        await _refresh();
      } while (_again && mounted);
    } finally {
      _refreshing = null;
      refresh.complete();
    }
  }

  Future<void> _refresh() async {
    try {
      final records = await widget.chatmail.matchHistory(
        widget.chat,
        widget.id,
      );
      if (mounted) {
        final match = OnlineMatch.replay(widget.id, records);
        setState(() {
          _syncTurn(match);
          _match = match;
          if (match?.started == true && match?.conflict == false) {
            _playing = true;
          }
          _error = _match == null
              ? 'The match invitation is unavailable.'
              : null;
        });
        if (match != null && match.active) {
          if (widget.acceptOnOpen &&
              !_acceptedFromChat &&
              !match.mine &&
              !match.accepted) {
            _acceptedFromChat = true;
            unawaited(_accept(match));
          } else if (match.accepted && _game == null && !_triedPreparation) {
            unawaited(_openBoard(match.invite.game!));
          }
        }
      }
      if (!_chatOpen && mounted) {
        try {
          final thread = await widget.chatmail.thread(widget.chat);
          if (mounted && !_chatOpen) {
            setState(() {
              _chatUnread =
                  !_chatOpen &&
                  (thread.messages.any(
                    (message) =>
                        !message.outgoing &&
                        !message.info &&
                        message.state == 10 &&
                        (!message.encrypted ||
                            MatchEvent.parse(message.text) == null),
                  ));
            });
          }
        } catch (_) {
          // The board remains available when the conversation refresh fails.
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t refresh this match.');
    }
  }

  Future<void> _accept(OnlineMatch match) async {
    if (_sending || match.mine || match.finished || match.accepted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final response = match.invite.accept();
      if (_game == null) {
        await widget.chatmail.checkMatchCapacity(widget.chat, response);
        if (!mounted) return;
        if (!match.preparing) {
          await widget.chatmail.send(
            widget.chat,
            match.invite.preparing().wire,
          );
        }
        if (!mounted) return;
        await _openBoard(match.invite.game!);
        if (_game == null || !mounted) return;
      }
      await widget.chatmail.sendMatchOpening(widget.chat, response);
      await _load();
    } on ActiveMatchLimit {
      if (mounted) setState(() => _error = ActiveMatchLimit.message);
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Couldn’t accept this match. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _quit(OnlineMatch match) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Quit this match?'),
        content: const Text('This ends the match for both players.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Keep playing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Quit match'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _match?.finished != false) return;
    await _send(match.invite.control('quit', match.nextRevision).wire);
    if (mounted &&
        _match?.quit == true &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context);
    }
  }

  Future<void> _send(String message) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (!mounted) return;
      final event = MatchEvent.parse(message);
      if (event?.kind == 'invite') {
        await widget.chatmail.sendMatchOpening(widget.chat, event!);
      } else {
        await widget.chatmail.send(widget.chat, message);
      }
      await _load();
    } on ActiveMatchLimit {
      if (mounted) setState(() => _error = ActiveMatchLimit.message);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Couldn’t send. Refresh the match before trying again.';
          // The Lua player holds the submitted column until its board changes.
          // Reopen it after a send error so an unchanged board can accept a retry.
          if (MatchEvent.parse(message)?.kind == 'move') _boardGeneration++;
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openBoard(GameLink link) async {
    if (_preparing) return;
    setState(() {
      _preparing = true;
      _triedPreparation = true;
      _gameUnavailable = false;
    });
    try {
      final game = await widget.prepareGame(link);
      if (mounted) {
        setState(() {
          _game = game;
          _gameUnavailable = game == null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _gameUnavailable = true);
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  void _move(int column) {
    final match = _match;
    if (match == null ||
        _sending ||
        _chatOpen ||
        _displayTurn != null ||
        !_playing ||
        _error != null ||
        !match.myTurn ||
        column < 0 ||
        column >= 7 ||
        match.board.landing(column) < 0)
      return;
    unawaited(_send(match.invite.move(match.moves, column).wire));
  }

  String _lobbyText(OnlineMatch? match) {
    final friend = widget.friendName ?? 'Your friend';
    if (_error case final error?) return error;
    if (_preparing) return 'Getting Cats vs Dogs ready…';
    if (_gameUnavailable) return 'Couldn’t prepare the game.';
    if (match == null) return 'Opening match…';
    if (match.finished || match.conflict || match.pending != null) {
      return match.status;
    }
    if (match.accepted && _game != null) {
      return match.mine
          ? '$friend is ready to play.'
          : 'Waiting for $friend to start the game.';
    }
    if (!match.accepted && !match.mine) {
      return '$friend invited you to play Cats vs Dogs.';
    }
    if (!match.accepted && match.preparing) {
      return 'Getting the game ready for ${widget.friendName ?? 'your friend'}…';
    }
    return match.status;
  }

  Widget _turnHeading(BuildContext context, OnlineMatch match) {
    final theme = Theme.of(context);
    if (match.finished ||
        match.paused ||
        match.pending != null ||
        match.conflict) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text(match.status, style: theme.textTheme.titleMedium),
      );
    }
    final side = _displayTurn ?? match.board.turn;
    final yours = (side == 1) == match.mine;
    final name = yours ? _myName : widget.friendName ?? 'Your friend';
    final piece = switch ((match.invite.game!.build >= 6, side)) {
      (true, 1) => '🐱',
      (true, _) => '🐶',
      (false, 1) => '🟡',
      (false, _) => '🟣',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ExcludeSemantics(
                  child: Text(piece, style: const TextStyle(fontSize: 24)),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            Text(
              yours ? 'Your Turn' : 'Their Turn',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: yours
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final match = _match;
    final pendingAction = MatchEvent.parse(match?.pending?.text ?? '');
    final pendingControl = pendingAction?.revision != null;
    final pendingQuit = pendingAction?.kind == 'quit';
    return PopScope(
      canPop: !_chatOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _chatOpen) _toggleChat();
      },
      child: Scaffold(
        appBar: _boardOpen
            ? GameToolbar(
                title: widget.friendName == null
                    ? 'Cats vs Dogs'
                    : 'Match with ${widget.friendName}',
                chat: widget.chat,
                friendName: widget.friendName,
                onMessage: _toggleChat,
                chatOpen: _chatOpen,
                unread: _chatUnread,
                paused: match!.pausedByMe,
                onPause:
                    _sending ||
                        pendingControl ||
                        match.finished ||
                        (match.pausedByFriend && !match.pausedByMe)
                    ? null
                    : () => _togglePause(match),
                onQuit: _sending || pendingQuit
                    ? null
                    : match.finished
                    ? () => Navigator.of(context).pop()
                    : () => _quit(match),
              )
            : AppBar(
                title: Text(
                  widget.friendName == null
                      ? 'Online Cats vs Dogs'
                      : 'Match with ${widget.friendName}',
                ),
                actions: [
                  ...chatActions(context),
                  IconButton(
                    tooltip: _chatOpen ? 'Close match chat' : 'Open match chat',
                    onPressed: _toggleChat,
                    icon: Badge(
                      isLabelVisible: _chatUnread,
                      child: const Icon(Icons.chat_outlined),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh match',
                    onPressed: _sending ? null : _load,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dockHeight = MediaQuery.viewInsetsOf(context).bottom > 0
                  ? constraints.maxHeight
                  : (constraints.maxHeight * .75)
                        .clamp(
                          constraints.maxHeight < 260
                              ? constraints.maxHeight
                              : 260.0,
                          constraints.maxHeight,
                        )
                        .toDouble();
              return Stack(
                children: [
                  Positioned.fill(
                    child:
                        _playing &&
                            match != null &&
                            _game != null &&
                            !match.quit
                        ? Stack(
                            fit: StackFit.expand,
                            children: [
                              Column(
                                children: [
                                  _turnHeading(context, match),
                                  Expanded(
                                    child: Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 560,
                                        ),
                                        child: AspectRatio(
                                          aspectRatio: 540 / 620,
                                          child: LoveGameView.official(
                                            key: ValueKey(
                                              '${widget.id}/${_game!.build}/$_boardGeneration',
                                            ),
                                            game: _game!,
                                            mode: 'online',
                                            paused: match.paused,
                                            match:
                                                '${match.board.cells.join()}:${match.board.turn}:${match.board.winner}:${!_sending && !_chatOpen && _displayTurn == null && _error == null && match.myTurn ? 1 : 0}',
                                            onMove: _move,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (match.paused ||
                                  pendingControl ||
                                  _error != null ||
                                  (match.pending?.state == 24 && !_sending))
                                Center(
                                  child: Card(
                                    child: Padding(
                                      padding: const EdgeInsets.all(18),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            _error ??
                                                (pendingControl
                                                    ? match.status
                                                    : match.pausedByMe
                                                    ? 'You paused the game.'
                                                    : match.pausedByFriend
                                                    ? '${widget.friendName ?? 'Your friend'} paused the game.'
                                                    : match.status),
                                          ),
                                          if (_error != null)
                                            TextButton(
                                              onPressed: _load,
                                              child: const Text('Refresh'),
                                            ),
                                          if (match.pending case final pending?
                                              when pending.state == 24)
                                            TextButton(
                                              onPressed: () =>
                                                  _send(pending.text),
                                              child: const Text('Retry send'),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          )
                        : Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(24),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 420,
                                ),
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(22),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_preparing ||
                                            _sending ||
                                            match?.pending?.state == 20 ||
                                            (match == null && _error == null))
                                          const LinearProgressIndicator(),
                                        const SizedBox(height: 12),
                                        Text(
                                          _lobbyText(match),
                                          textAlign: TextAlign.center,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge,
                                        ),
                                        if (match != null &&
                                            match.active &&
                                            !match.conflict) ...[
                                          const SizedBox(height: 12),
                                          if (match.accepted &&
                                              match.mine &&
                                              match.pending == null &&
                                              _game != null)
                                            FilledButton(
                                              onPressed: _sending
                                                  ? null
                                                  : () => _send(
                                                      match.invite
                                                          .control(
                                                            'resume',
                                                            match.nextRevision,
                                                          )
                                                          .wire,
                                                    ),
                                              child: const Text('Play Now'),
                                            )
                                          else if (!match.accepted &&
                                              match.pending == null &&
                                              !match.mine)
                                            Wrap(
                                              alignment: WrapAlignment.center,
                                              spacing: 12,
                                              children: [
                                                OutlinedButton(
                                                  onPressed: _sending
                                                      ? null
                                                      : () => _send(
                                                          match.invite
                                                              .decline()
                                                              .wire,
                                                        ),
                                                  style:
                                                      OutlinedButton.styleFrom(
                                                        foregroundColor:
                                                            Theme.of(context)
                                                                .colorScheme
                                                                .error,
                                                      ),
                                                  child: const Text('Decline'),
                                                ),
                                                FilledButton(
                                                  onPressed:
                                                      _sending || _preparing
                                                      ? null
                                                      : () => _accept(match),
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor:
                                                        const Color(0xff1b663c),
                                                    foregroundColor:
                                                        Colors.white,
                                                  ),
                                                  child: const Text('Accept'),
                                                ),
                                              ],
                                            )
                                          else if (_gameUnavailable)
                                            FilledButton(
                                              onPressed: _preparing
                                                  ? null
                                                  : () => _openBoard(
                                                      match.invite.game!,
                                                    ),
                                              child: const Text(
                                                'Retry download',
                                              ),
                                            ),
                                          if (match.pending case final pending?
                                              when pending.state == 24)
                                            TextButton(
                                              onPressed: _sending
                                                  ? null
                                                  : () => _send(pending.text),
                                              child: const Text('Retry send'),
                                            ),
                                        ],
                                        if (_error != null)
                                          TextButton(
                                            onPressed: _load,
                                            child: const Text('Refresh'),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                  if (_boardOpen)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 12,
                      child: IgnorePointer(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: !_chatOpen && _messagePreview != null
                              ? Semantics(
                                  key: ValueKey(_latestMessage),
                                  liveRegion: true,
                                  child: Center(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: const Color(0xe61b1c20),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 10,
                                        ),
                                        child: Text(
                                          _messagePreview!,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: dockHeight,
                    child: IgnorePointer(
                      ignoring: !_chatOpen,
                      child: ClipRect(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          reverseDuration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          layoutBuilder: (current, previous) => Stack(
                            fit: StackFit.expand,
                            children: [
                              ...previous,
                              if (current != null) current,
                            ],
                          ),
                          transitionBuilder: (child, animation) =>
                              SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, -1),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                          child: _chatOpen
                              ? Material(
                                  key: const ValueKey('match-chat'),
                                  elevation: 12,
                                  clipBehavior: Clip.antiAlias,
                                  borderRadius: const BorderRadius.vertical(
                                    bottom: Radius.circular(18),
                                  ),
                                  child: Column(
                                    children: [
                                      Expanded(
                                        child: widget.buildChatDock(
                                          _toggleChat,
                                        ),
                                      ),
                                      Center(
                                        child: TextButton(
                                          onPressed: _toggleChat,
                                          style: TextButton.styleFrom(
                                            minimumSize: const Size(96, 44),
                                          ),
                                          child: Semantics(
                                            label: 'Close chat panel',
                                            child: ExcludeSemantics(
                                              child: Icon(
                                                Icons.horizontal_rule,
                                                size: 36,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
