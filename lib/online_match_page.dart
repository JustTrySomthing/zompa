import 'dart:async';

import 'package:flutter/material.dart';

import 'brand.dart';
import 'chatmail.dart';
import 'game_link.dart';
import 'online_match.dart';

class OnlineMatchPage extends StatefulWidget {
  const OnlineMatchPage({
    super.key,
    required this.chatmail,
    required this.chat,
    required this.id,
    required this.prepareGame,
  });

  final Chatmail chatmail;
  final int chat;
  final String id;
  final Future<bool> Function(GameLink) prepareGame;

  @override
  State<OnlineMatchPage> createState() => _OnlineMatchPageState();
}

class _OnlineMatchPageState extends State<OnlineMatchPage>
    with WidgetsBindingObserver {
  OnlineMatch? _match;
  StreamSubscription<void>? _events;
  Timer? _timer;
  bool _loading = false, _again = false, _sending = false;
  String? _error;

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
      if (prepare != null && !await widget.prepareGame(prepare)) return;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Online Drop Four'),
        actions: [
          IconButton(
            tooltip: 'Refresh match',
            onPressed: _sending ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
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
                  onPressed: _sending ? null : () => _send(pending.text),
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
              if (match.accepted)
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Card(
                      color: ZompadoBrand.darkPanel,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Row(
                          children: [
                            for (var column = 0; column < 7; column++)
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  label: 'Drop piece in column ${column + 1}',
                                  child: InkWell(
                                    onTap:
                                        !_sending &&
                                            _error == null &&
                                            match.myTurn &&
                                            match.board.landing(column) >= 0
                                        ? () => _send(
                                            match.invite
                                                .move(match.moves, column)
                                                .wire,
                                          )
                                        : null,
                                    child: Column(
                                      children: [
                                        for (var row = 0; row < 6; row++)
                                          AspectRatio(
                                            aspectRatio: 1,
                                            child: Padding(
                                              padding: const EdgeInsets.all(3),
                                              child: DecoratedBox(
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: switch (match
                                                      .board
                                                      .cells[row * 7 +
                                                      column]) {
                                                    1 => const Color(
                                                      0xffffc65a,
                                                    ),
                                                    2 => const Color(
                                                      0xffcab1ff,
                                                    ),
                                                    _ => ZompadoBrand.ink,
                                                  },
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (match.accepted)
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
    );
  }
}
