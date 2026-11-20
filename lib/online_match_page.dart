import 'dart:async';

import 'package:flutter/material.dart';

import 'chatmail.dart';
import 'game_link.dart';
import 'github_distribution.dart';
import 'online_match.dart';
import 'love_player.dart';
import 'game_audio.dart';

class OnlineMatchPage extends StatefulWidget {
  const OnlineMatchPage({
    super.key,
    required this.chatmail,
    required this.chat,
    required this.id,
    required this.prepareGame,
    required this.buildChatDock,
    this.friendName,
  });

  final Chatmail chatmail;
  final int chat;
  final String id;
  final Future<GameRelease?> Function(GameLink) prepareGame;
  final Widget Function(VoidCallback close) buildChatDock;
  final String? friendName;

  @override
  State<OnlineMatchPage> createState() => _OnlineMatchPageState();
}

class _OnlineMatchPageState extends State<OnlineMatchPage>
    with WidgetsBindingObserver {
  OnlineMatch? _match;
  GameRelease? _game;
  bool _preparing = false;
  bool _triedPreparation = false;
  bool _gameUnavailable = false;
  int _boardGeneration = 0;
  StreamSubscription<void>? _events;
  Timer? _timer;
  Completer<void>? _refreshing;
  bool _again = false, _sending = false;
  String? _error;
  bool _chatOpen = false;
  bool _chatUnread = false;

  void _toggleChat() {
    if (_chatOpen) FocusScope.of(context).unfocus();
    setState(() {
      _chatOpen = !_chatOpen;
      if (_chatOpen) _chatUnread = false;
    });
    unawaited(_load());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _events = widget.chatmail.changes.listen((_) {
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 180), _load);
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
    _events?.cancel();
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
          _match = match;
          _error = _match == null
              ? 'The match invitation is unavailable.'
              : null;
        });
        if (match?.accepted == true && _game == null && !_triedPreparation) {
          unawaited(_openBoard(match!.invite.game!));
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

  Future<void> _send(String message, {GameLink? prepare}) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (prepare != null && _game == null) {
        await _openBoard(prepare);
        if (_game == null) return;
      }
      if (!mounted) return;
      await widget.chatmail.send(widget.chat, message);
      await _load();
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
        _error != null ||
        !match.myTurn ||
        column < 0 ||
        column >= 7 ||
        match.board.landing(column) < 0)
      return;
    unawaited(_send(match.invite.move(match.moves, column).wire));
  }

  @override
  Widget build(BuildContext context) {
    final match = _match;
    return PopScope(
      canPop: !_chatOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _chatOpen) _toggleChat();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.friendName == null
                ? 'Online Cats vs Dogs'
                : 'Match with ${widget.friendName}',
          ),
          actions: [
            const GameAudioButton(),
            IconButton(
              tooltip: _chatOpen
                  ? 'Close match chat'
                  : _chatUnread
                  ? 'Open match chat, unread messages'
                  : 'Open match chat',
              onPressed: _toggleChat,
              icon: Badge(
                isLabelVisible: _chatUnread,
                child: const Icon(Icons.chat_bubble_outline),
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
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_sending ||
                            _preparing ||
                            (match == null && _error == null))
                          const LinearProgressIndicator(),
                        if (_error case final error?)
                          ListTile(
                            title: Text(error),
                            trailing: TextButton(
                              onPressed: _load,
                              child: const Text('Refresh'),
                            ),
                          ),
                        if (match != null) ...[
                          Text(
                            match.status,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          if (_preparing)
                            const Text('Getting Cats vs Dogs ready…'),
                          if (_gameUnavailable)
                            const Text(
                              'Couldn’t prepare this match’s game. Check your connection and try again.',
                            ),
                          if (!match.accepted && match.mine && !match.conflict)
                            const Text(
                              'You go first. You can leave this screen and return from Online matches.',
                            ),
                          if (!match.accepted &&
                              !match.mine &&
                              !match.conflict &&
                              match.pending == null)
                            FilledButton(
                              onPressed: _sending
                                  ? null
                                  : () => _send(
                                      match.invite.accept().wire,
                                      prepare: match.invite.game,
                                    ),
                              child: const Text('Accept and open match'),
                            ),
                          if (match.pending case final pending?
                              when pending.state == 24 && !match.conflict)
                            OutlinedButton(
                              onPressed: _sending
                                  ? null
                                  : () => _send(pending.text),
                              child: const Text('Retry send'),
                            ),
                          const SizedBox(height: 12),
                          if (match.accepted && _game != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                (_game?.build ?? 0) >= 6
                                    ? (match.mine
                                          ? 'You play as Cats'
                                          : 'You play as Dogs')
                                    : (match.mine
                                          ? 'Your pieces are gold'
                                          : 'Your pieces are purple'),
                              ),
                            ),
                          if (match.accepted && _gameUnavailable)
                            FilledButton(
                              onPressed: _preparing
                                  ? null
                                  : () => _openBoard(match.invite.game!),
                              child: const Text('Try opening the board again'),
                            ),
                          if (_game case final GameRelease game
                              when match.accepted)
                            Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 560,
                                ),
                                child: AspectRatio(
                                  aspectRatio: 540 / 620,
                                  child: LoveGameView.official(
                                    key: ValueKey(
                                      '${widget.id}/${game.build}/$_boardGeneration',
                                    ),
                                    game: game,
                                    mode: 'online',
                                    match:
                                        '${match.board.cells.join()}:${match.board.turn}:${match.board.winner}:${!_sending && !_chatOpen && _error == null && match.myTurn ? 1 : 0}',
                                    onMove: _move,
                                  ),
                                ),
                              ),
                            ),
                          if (match.accepted && _game != null)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text(
                                'On your turn, tap a column to drop a piece.',
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (_chatOpen)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: dockHeight,
                      child: widget.buildChatDock(_toggleChat),
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
