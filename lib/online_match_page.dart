import 'chat_chrome.dart';

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
    _playing = widget.playOnOpen;
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
        if (match != null && !match.finished) {
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
      if (_game == null) {
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
      await widget.chatmail.send(widget.chat, match.invite.accept().wire);
      await _load();
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
    if (mounted && _match?.quit == true) Navigator.pop(context);
  }

  Future<void> _send(String message) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
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
    if (match.finished) return match.status;
    if (match.accepted && _game != null) {
      return match.mine ? '$friend is ready to play.' : 'You’re ready to play.';
    }
    if (!match.accepted && !match.mine) {
      return '$friend invited you to play Cats vs Dogs.';
    }
    if (!match.accepted && match.preparing) {
      return 'Getting the game ready for ${widget.friendName ?? 'your friend'}…';
    }
    return match.status;
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
            ...chatActions(context),
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
                                  const SizedBox(height: 8),
                                  Text(
                                    match.status,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  if (_game!.build >= 6)
                                    Text(
                                      match.mine
                                          ? 'You play as Cats'
                                          : 'You play as Dogs',
                                    )
                                  else
                                    Text(
                                      match.mine
                                          ? 'Your pieces are gold'
                                          : 'Your pieces are purple',
                                    ),
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
                                                '${match.board.cells.join()}:${match.board.turn}:${match.board.winner}:${!_sending && !_chatOpen && _error == null && match.myTurn ? 1 : 0}',
                                            onMove: _move,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (!match.finished)
                                    Wrap(
                                      alignment: WrapAlignment.center,
                                      spacing: 12,
                                      children: [
                                        TextButton.icon(
                                          onPressed:
                                              _sending ||
                                                  (match.pausedByFriend &&
                                                      !match.pausedByMe)
                                              ? null
                                              : () => _send(
                                                  match.invite
                                                      .control(
                                                        match.pausedByMe
                                                            ? 'resume'
                                                            : 'pause',
                                                        match.nextRevision,
                                                      )
                                                      .wire,
                                                ),
                                          icon: Icon(
                                            match.pausedByMe
                                                ? Icons.play_arrow
                                                : Icons.pause,
                                          ),
                                          label: Text(
                                            match.pausedByMe
                                                ? 'Resume'
                                                : 'Pause',
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: _sending
                                              ? null
                                              : () => _quit(match),
                                          child: const Text('Quit'),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                              if (match.paused ||
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
                                                (match.pausedByMe
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
                                            !match.finished &&
                                            !match.conflict) ...[
                                          const SizedBox(height: 12),
                                          if (match.accepted && _game != null)
                                            FilledButton(
                                              onPressed: _sending
                                                  ? null
                                                  : () => setState(
                                                      () => _playing = true,
                                                    ),
                                              child: const Text('Play Now'),
                                            )
                                          else if (!match.accepted &&
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
