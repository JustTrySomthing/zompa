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
  });

  final Chatmail chatmail;
  final int chat;
  final String id;
  final Future<GameRelease?> Function(GameLink) prepareGame;
  final Widget Function(VoidCallback close) buildChatDock;

  @override
  State<OnlineMatchPage> createState() => _OnlineMatchPageState();
}

class _OnlineMatchPageState extends State<OnlineMatchPage>
    with WidgetsBindingObserver {
  OnlineMatch? _match;
  GameRelease? _game;
  bool _preparing = false;
  StreamSubscription<void>? _events;
  Timer? _timer;
  bool _loading = false, _again = false, _sending = false;
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
    if (_loading) {
      _again = true;
      return;
    }
    _loading = true;
    try {
      final records = await widget.chatmail.matchHistory(
        widget.chat,
        widget.id,
      );
      if (mounted) {
        setState(() {
          _match = OnlineMatch.replay(widget.id, records);
          _error = _match == null
              ? 'The match invitation is unavailable.'
              : null;
        });
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
    } finally {
      _loading = false;
      if (_again) {
        _again = false;
        unawaited(_load());
      }
    }
  }

  Future<void> _send(String message, {GameLink? prepare}) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (prepare != null) {
        final game = await widget.prepareGame(prepare);
        if (!mounted || game == null) return;
        setState(() => _game = game);
      }
      if (!mounted) return;
      await widget.chatmail.send(widget.chat, message);
      await _load();
    } catch (_) {
      if (mounted)
        setState(
          () =>
              _error = 'Couldn’t send. Refresh the match before trying again.',
        );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openBoard(GameLink link) async {
    if (_preparing) return;
    setState(() => _preparing = true);
    try {
      final game = await widget.prepareGame(link);
      if (mounted && game != null) setState(() => _game = game);
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

  String _status(OnlineMatch match) {
    if (match.conflict) return 'Conflicting turns. Start a new match.';
    if (match.pending?.state == 20) return 'Sending…';
    if (match.pending?.state == 24) return 'Couldn’t send this match update.';
    if (!match.accepted)
      return match.mine
          ? 'Waiting for your friend to accept.'
          : 'Your friend invited you to a match.';
    if (match.board.winner != 0) {
      return (match.board.winner == 1) == match.mine
          ? 'You won!'
          : 'Your friend won.';
    }
    if (match.board.full) return 'Draw.';
    return match.myTurn ? 'Your turn' : 'Your friend’s turn';
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
          title: const Text('Online Drop Four'),
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
                        if (_sending || (match == null && _error == null))
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
                            _status(match),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          if (!match.accepted && !match.mine && !match.conflict)
                            FilledButton(
                              onPressed: _sending
                                  ? null
                                  : () => _send(
                                      match.invite.accept().wire,
                                      prepare: match.invite.game,
                                    ),
                              child: const Text('Install if needed and accept'),
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
                          if (match.accepted)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                match.mine
                                    ? 'Your pieces are gold.'
                                    : 'Your pieces are purple.',
                              ),
                            ),
                          if (match.accepted && _game == null)
                            FilledButton(
                              onPressed: _preparing
                                  ? null
                                  : () => _openBoard(match.invite.game!),
                              child: Text(
                                _preparing
                                    ? 'Preparing game…'
                                    : 'Install if needed and open board',
                              ),
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
                                    key: ValueKey('${widget.id}/${game.build}'),
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
                                'Tap a column to drop a piece. Use Back to return to the conversation.',
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
