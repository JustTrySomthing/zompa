import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chat_chrome.dart';
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
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  OnlineMatch? _match;
  GameRelease? _game;
  bool _preparing = false;
  bool _acceptedFromChat = false;
  bool _playing = false;
  bool _triedPreparation = false;
  bool _gameUnavailable = false;
  var _helpPlayer = GlobalKey<LoveGameViewState>();
  String? _playerIdentity;
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
  String? _incomingRematch;
  int _rematchMessage = 0;

  Timer? _turnTimer;
  int? _displayTurn;
  late final AnimationController _celebration;
  (int, String)? _celebratedResult;

  void _updateCelebration() {
    final match = _match;
    if (_displayTurn != null ||
        match == null ||
        match.board.winner == 0 ||
        match.pending != null ||
        match.quit ||
        match.conflict) {
      if (_celebration.isAnimating) _celebration.value = 1;
      return;
    }
    final result = (match.round, match.moves);
    if (_celebratedResult == result) return;
    _celebratedResult = result;
    if (!_boardOpen || MediaQuery.disableAnimationsOf(context)) return;
    _celebration.duration = Duration(milliseconds: match.finished ? 2100 : 950);
    _celebration.forward(from: 0);
  }

  void _syncTurn(OnlineMatch? match) {
    if (match == null) return;
    final previous = _match;
    if (previous != null &&
        match.round == previous.round &&
        match.moves.length == previous.moves.length + 1) {
      _turnTimer?.cancel();
      _displayTurn = previous.board.turn;
      _turnTimer = Timer(const Duration(milliseconds: 740), () {
        if (!mounted) return;
        setState(() => _displayTurn = null);
        _updateCelebration();
      });
    } else if (previous?.round != match.round ||
        previous?.moves != match.moves) {
      _turnTimer?.cancel();
      _displayTurn = null;
    }
  }

  bool get _boardOpen =>
      _playing && _match != null && _game != null && !_match!.quit;

  void _togglePause(OnlineMatch match) {
    if (_sending ||
        match.finished ||
        match.boardComplete ||
        (match.pausedByFriend && !match.pausedByMe))
      return;
    final action = match.pausedByMe ? 'resume' : 'pause';
    unawaited(_send(match.invite.control(action, match.nextRevision).wire));
  }

  Future<void> _checkRematch(int chat, int id) async {
    if (chat != widget.chat ||
        (!_boardOpen && _match?.boardComplete != true) ||
        id <= _rematchMessage)
      return;
    try {
      final target = await widget.chatmail.notificationMessage(
        chat,
        id,
        forDelivery: false,
      );
      if (!mounted || target == null || id <= _rematchMessage) return;
      final match = _match;
      if (match == null) return;
      final event = MatchEvent.parse(target.message.text);
      if (event != null &&
          event.kind == 'invite' &&
          event.rematchOf == match.invite.id &&
          event.game.toString() == match.invite.game.toString()) {
        setState(() {
          _incomingRematch = event.id;
          _rematchMessage = id;
        });
      }
    } catch (_) {
      // An unreadable invitation does not interrupt the game.
    }
  }

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
    _celebration = AnimationController(vsync: this, value: 1)
      ..addStatusListener((status) {
        if (mounted && status == AnimationStatus.completed) setState(() {});
      });
    _playing = widget.playOnOpen;
    _messages = widget.chatmail.incoming.listen((event) {
      unawaited(_checkRematch(event.$1, event.$2));
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) && _celebration.isAnimating) {
      _celebration.value = 1;
    }
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
    _turnTimer?.cancel();
    _celebration.dispose();
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
          if (match != null) {
            _syncTurn(match);
            _match = match;
            if (match.started && !match.conflict) _playing = true;
          }
          _error = match == null
              ? 'The match invitation is unavailable.'
              : null;
        });
        _updateCelebration();
        if (match != null && match.active && !match.conflict) {
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
          final unread = thread.messages.any(
            (message) => message.isUnreadChatMessage,
          );
          if (mounted && !_chatOpen && _chatUnread != unread) {
            setState(() => _chatUnread = unread);
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
        await widget.chatmail.checkInviteExpiry(widget.chat, response.id);
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
      final moved = await widget.chatmail.sendMatchOpening(
        widget.chat,
        response,
      );
      await _load();
      if (mounted && moved != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(matchMovedNotice(moved))));
      }
    } on MatchInviteExpired {
      await _load();
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Couldn’t accept this match. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _quit() async {
    final confirmed = await confirmQuitMatch(
      context,
      message: 'This ends the match for both players.',
    );
    final current = _match;
    if (!mounted || confirmed != true || current == null || current.finished)
      return;
    await _send(current.invite.control('quit', current.nextRevision).wire);
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
      if (MatchEvent.parse(message) case final event?
          when event.kind == 'invite') {
        await _sendInvitation(event);
      } else {
        await widget.chatmail.send(widget.chat, message);
      }
      await _load();
    } on MatchInviteExpired {
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

  Future<void> _rematch(OnlineMatch match) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final invitation = MatchEvent.invite(
      match.invite.game!,
      rematchOf: match.invite.id,
    );
    try {
      await _sendInvitation(invitation);
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      _openRematch(invitation.id);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Couldn’t send a rematch invite. Try again.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendInvitation(MatchEvent invitation) async {
    final moved = await widget.chatmail.sendMatchOpening(
      widget.chat,
      invitation,
    );
    if (mounted && moved != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(matchMovedNotice(moved))));
    }
  }

  void _openRematch(String id, {bool accept = false}) {
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute(
        builder: (_) => OnlineMatchPage(
          chatmail: widget.chatmail,
          chat: widget.chat,
          id: id,
          prepareGame: widget.prepareGame,
          buildChatDock: widget.buildChatDock,
          friendName: widget.friendName,
          acceptOnOpen: accept,
        ),
      ),
    );
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
    unawaited(
      _send(match.invite.move(match.moves, column, round: match.round).wire),
    );
  }

  String _lobbyText(OnlineMatch? match) {
    if (match != null && match.boardComplete && match.pending == null)
      return match.status;
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

  String _gameWinner(OnlineMatch match) {
    final name = widget.friendName?.trim();
    return (match.board.winner == 1) == match.mine
        ? 'You win the game!'
        : "${name == null || name.isEmpty ? 'Your friend' : name} wins the game!";
  }

  Widget _turnHeading(
    BuildContext context,
    OnlineMatch match,
    GameRelease game,
  ) {
    final boardSettled = match.boardComplete && _displayTurn == null;
    final winner = boardSettled ? match.board.winner : 0;
    final side = winner != 0 ? winner : _displayTurn ?? match.board.turn;
    final yours = (side == 1) == match.mine;
    final friend = widget.friendName?.trim();
    final name = friend == null || friend.isEmpty ? 'Your friend' : friend;
    final statusOnly =
        (boardSettled && winner == 0) || match.paused || match.conflict;
    final label = statusOnly
        ? match.status
        : winner != 0
        ? (yours
              ? 'You win Round ${match.round}'
              : '$name wins Round ${match.round}')
        : (yours ? 'Your turn' : '$name’s turn');

    final finale = winner != 0 && match.finished && !statusOnly;
    final cats = match.mine;
    final hasAnimalArt = game.build >= 6;
    final heading = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Center(
        child: LayoutBuilder(
          builder: (context, bounds) => FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: bounds.maxWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!finale && hasAnimalArt)
                    Image.asset(
                      cats
                          ? 'assets/games/cat-token.webp'
                          : 'assets/games/dog-token.webp',
                      width: 36,
                      height: 36,
                      semanticLabel: cats ? 'You play Cats' : 'You play Dogs',
                    )
                  else if (!finale)
                    Semantics(
                      label: cats ? 'You play Yellow' : 'You play Purple',
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: cats
                            ? const Color(0xffffcf50)
                            : const Color(0xffa987ff),
                      ),
                    ),
                  if (!finale) const SizedBox(height: 5),
                  if (finale)
                    _winBanner(
                      _gameWinner(match),
                      winner,
                      finale: true,
                      stars: match.series ? 3 : 1,
                    )
                  else if (winner != 0 && !statusOnly)
                    _winBanner(label, winner)
                  else
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: const Color(0xfffff4fc),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (winner == 0 || statusOnly) return heading;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _MatchFireworks(
              progress: _celebration,
              finale: finale,
              accent: winner == 1
                  ? const Color(0xffff9abb)
                  : const Color(0xffa6ddff),
            ),
          ),
          Center(child: heading),
        ],
      ),
    );
  }

  Widget _winBanner(
    String label,
    int winner, {
    bool finale = false,
    int stars = 0,
  }) {
    final accent = winner == 1
        ? const Color(0xffff9abb)
        : const Color(0xffa6ddff);
    const background = Color(0xff201a31);
    final banner = Semantics(
      liveRegion: true,
      header: true,
      child: Container(
        constraints: BoxConstraints(maxWidth: finale ? 400 : 420),
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: finale ? 24 : 7,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              background.withValues(alpha: .84),
              Color.alphaBlend(
                accent.withValues(alpha: .20),
                background,
              ).withValues(alpha: .84),
              background.withValues(alpha: .84),
            ],
          ),
          border: Border.all(color: accent),
          borderRadius: BorderRadius.circular(finale ? 24 : 12),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: .35),
              blurRadius: finale ? 28 : 12,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (stars > 0) ...[
              AnimatedBuilder(
                animation: _celebration,
                builder: (context, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (var i = 0; i < stars; i++) _victoryStar(i)],
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: const Color(0xfffff4fc),
                fontSize: finale ? 42 : 24,
                height: 1.08,
                letterSpacing: .5,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w900,
                shadows: [
                  Shadow(color: accent.withValues(alpha: .65), blurRadius: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final fitted = finale
        ? ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 168),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(width: 368, child: banner),
            ),
          )
        : banner;
    if (MediaQuery.disableAnimationsOf(context)) return fitted;
    return TweenAnimationBuilder<double>(
      key: ValueKey(label),
      tween: Tween(begin: .86, end: 1),
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeOutBack,
      child: fitted,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
    );
  }

  Widget _victoryStar(int index) {
    final progress = ((_celebration.value - .15 - index * .13) / .22).clamp(
      0.0,
      1.0,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: SizedBox(
        width: 38,
        height: 38,
        child: Opacity(
          opacity: progress,
          child: Transform.scale(
            scale: .48 + .52 * Curves.easeOutBack.transform(progress),
            child: const Icon(
              Icons.star_rounded,
              color: Color(0xffffd86f),
              size: 38,
            ),
          ),
        ),
      ),
    );
  }

  Widget _arena(BuildContext context, OnlineMatch match, GameRelease game) {
    final identity = '${widget.id}/${game.build}/$_boardGeneration';
    if (_playerIdentity != identity) {
      _playerIdentity = identity;
      _helpPlayer = GlobalKey<LoveGameViewState>();
    }
    final themedGame = game.build >= 12;
    const arenaColor = Color(0xff181423);
    return ColoredBox(
      color: themedGame ? arenaColor : const Color(0xff0b0d1c),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final aspect = 540 / (themedGame ? 665 : 620);
          final footer = match.series;
          final reserved = (bounds.maxHeight * (footer ? .35 : .24)).clamp(
            0.0,
            footer ? 156.0 : 88.0,
          );
          final boardHeight = (bounds.maxHeight - reserved).clamp(
            0.0,
            bounds.maxWidth.clamp(0.0, 560.0) / aspect,
          );
          final topInset = ((bounds.maxHeight - boardHeight) * .18).clamp(
            0.0,
            22.0,
          );
          return Column(
            children: [
              SizedBox(height: topInset),
              Expanded(child: _turnHeading(context, match, game)),
              SizedBox(
                key: ValueKey('${widget.id}/${game.build}/$_boardGeneration'),
                width: boardHeight * aspect,
                height: boardHeight,
                child: LoveGameView.official(
                  key: _helpPlayer,
                  game: game,
                  mode: 'online',
                  paused: match.paused && !match.boardComplete,
                  match:
                      '${match.board.cells.join()}:${match.board.turn}:${match.board.winner}:${!_sending && !_chatOpen && _displayTurn == null && _error == null && match.myTurn ? 1 : 0}'
                      '${match.series ? ':${match.scores.join(':')}' : ''}',
                  onMove: _move,
                ),
              ),
              Expanded(
                child: footer
                    ? Transform.translate(
                        // The themed board canvas has 70 units below the frame.
                        offset: Offset(
                          0,
                          themedGame ? -35 * boardHeight / 665 : 0,
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'ROUND ${match.round}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                          color: const Color(0xfffff4fc),
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 2,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'First Player to win 3 Rounds,\nWins the Game',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          color: const Color(0xffdbd1eb),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _finishedActions(OnlineMatch match) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Card(
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: _resultActions(match, scrollDetails: true),
        ),
      ),
    ),
  );

  Widget _resultActions(OnlineMatch match, {bool scrollDetails = false}) {
    final winner = match.board.winner;
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!scrollDetails && match.finished && winner != 0) ...[
          _winBanner(
            _gameWinner(match),
            winner,
            finale: true,
            stars: match.series ? 3 : 1,
          ),
          const SizedBox(height: 16),
        ],
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (match.finished && _incomingRematch != null)
          const Text(
            'Your friend invited you to play again.',
            textAlign: TextAlign.center,
          ),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (scrollDetails)
          Flexible(child: SingleChildScrollView(child: details))
        else
          details,
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            TextButton(
              onPressed: _sending
                  ? null
                  : match.finished
                  ? () => Navigator.pop(context)
                  : _quit,
              child: const Text('Quit'),
            ),
            FilledButton(
              onPressed: _sending
                  ? null
                  : () {
                      if (!match.finished) {
                        unawaited(
                          _send(
                            match.invite
                                .nextRound(match.round, match.moves)
                                .wire,
                          ),
                        );
                      } else if (_incomingRematch case final id?) {
                        _openRematch(id, accept: true);
                      } else {
                        _rematch(match);
                      }
                    },
              child: Text(
                !match.finished
                    ? 'Next round'
                    : _incomingRematch == null
                    ? 'Play another match'
                    : 'Accept rematch',
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final match = _match;
    final pendingAction = MatchEvent.parse(match?.pending?.text ?? '');
    final pendingControl = pendingAction?.revision != null;
    final pendingQuit = pendingAction?.kind == 'quit';
    final showResult =
        match != null &&
        match.boardComplete &&
        match.pending == null &&
        _displayTurn == null;
    final page = PopScope(
      canPop: !_chatOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _chatOpen) _toggleChat();
      },
      child: Scaffold(
        appBar: _boardOpen
            ? GameToolbar(
                title: _game!.title,
                onHelp: () => showGameInstructions(context, _helpPlayer.currentState?.instructions(), fourInARow: _game!.id == 'drop-four'),
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
                        match.boardComplete ||
                        (match.pausedByFriend && !match.pausedByMe)
                    ? null
                    : () => _togglePause(match),
              )
            : chatPageBar(
                context,
                widget.friendName == null
                    ? 'Online Cats vs Dogs'
                    : 'Match with ${widget.friendName}',
                fitTitle: widget.friendName == null,
                lastActions: [
                  MatchChatButton(
                    open: _chatOpen,
                    unread: _chatUnread,
                    onPressed: _toggleChat,
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
                              _arena(context, match, _game!),
                              if (showResult)
                                if (!match.finished ||
                                    !_celebration.isAnimating)
                                  _finishedActions(match)
                                else
                                  const SizedBox.shrink()
                              else if (match.paused ||
                                  pendingControl ||
                                  _error != null ||
                                  (match.pending?.state == 24 && !_sending))
                                Center(
                                  child: Card(
                                    child: SingleChildScrollView(
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
                                          if ((match.paused ||
                                                  pendingAction?.kind ==
                                                      'pause') &&
                                              !match.finished &&
                                              !pendingQuit)
                                            TextButton(
                                              onPressed: _sending
                                                  ? null
                                                  : _quit,
                                              child: const Text('Quit match'),
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
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleLarge,
                                        ),
                                        if (showResult) _resultActions(match),
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

                                                  child: const Text('Decline'),
                                                ),
                                                FilledButton(
                                                  onPressed:
                                                      _sending || _preparing
                                                      ? null
                                                      : () => _accept(match),

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
                                        if (_error != null && !showResult)
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
    return ChatAlertView(chat: widget.chat, matchId: widget.id, child: page);
  }
}

class _MatchFireworks extends CustomPainter {
  _MatchFireworks({
    required this.progress,
    required this.finale,
    required this.accent,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final bool finale;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final time = progress.value;
    if (time >= 1 || size.isEmpty) return;
    final paint = Paint()..strokeCap = StrokeCap.round;
    final bursts = finale ? 7 : 3;
    for (var burst = 0; burst < bursts; burst++) {
      final age =
          (time - (finale ? burst * .09 : burst * .12)) / (finale ? .44 : .73);
      if (age < 0 || age >= 1) continue;
      final x = size.width * (.12 + (burst * 37 % 77) / 100);
      final y = size.height * (.25 + (burst % 3) * .22);
      final origin = Offset(x, y);
      final distance =
          (.13 + (burst % 3) * .026) *
          math.min(size.width, size.height * 4) *
          Curves.easeOutCubic.transform(age);
      for (var spark = 0; spark < 14; spark++) {
        final angle = spark * math.pi / 7 + burst * .34;
        final direction = Offset(math.cos(angle), math.sin(angle));
        final end = origin + direction * (distance * (.72 + (spark % 4) * .1));
        paint
          ..strokeWidth = finale ? 2.6 : 2.1
          ..color = (spark.isEven ? accent : const Color(0xffffdf86))
              .withValues(alpha: (1 - age) * .92);
        canvas.drawLine(end - direction * (4 + 7 * (1 - age)), end, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_MatchFireworks oldDelegate) =>
      progress != oldDelegate.progress ||
      finale != oldDelegate.finale ||
      accent != oldDelegate.accent;
}
