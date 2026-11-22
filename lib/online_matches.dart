import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chatmail.dart';
import 'dialog_actions.dart';
import 'friends.dart';
import 'game_link.dart';
import 'game_play_page.dart';
import 'github_distribution.dart';
import 'online_match.dart';
import 'online_match_page.dart';

typedef LocalGameEntry = ({GameRelease game, String mode});

Future<void> showActiveGames(
  BuildContext context, {
  required Chatmail? chatmail,
  required Future<GameRelease?> Function(GameLink) prepareGame,
  GameRelease? game,
  Future<List<LocalGameEntry>> Function()? localGames,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => FractionallySizedBox(
    heightFactor: .82,
    child: _ActiveGamesSheet(
      chatmail: chatmail,
      prepareGame: prepareGame,
      game: game,
      localGames: localGames,
    ),
  ),
);

class _ActiveGamesSheet extends StatefulWidget {
  const _ActiveGamesSheet({
    required this.chatmail,
    required this.prepareGame,
    this.game,
    this.localGames,
  });

  final Chatmail? chatmail;
  final Future<List<LocalGameEntry>> Function()? localGames;
  final Future<GameRelease?> Function(GameLink) prepareGame;
  final GameRelease? game;

  @override
  State<_ActiveGamesSheet> createState() => _ActiveGamesSheetState();
}

class _ActiveGamesSheetState extends State<_ActiveGamesSheet>
    with WidgetsBindingObserver {
  StreamSubscription<void>? _events;
  Timer? _timer;
  bool _loading = false;
  bool _reload = false;
  List<MatchEntry> _matches = [];
  List<LocalGameEntry> _local = [];
  bool _localFailed = false;
  bool _refreshLocal = true;
  bool _loaded = false;
  bool _failed = false;
  String? _actionError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _events = widget.chatmail?.changes.listen((_) {
      _timer?.cancel();
      _timer = Timer(const Duration(milliseconds: 300), _load);
    });
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshLocal = true;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (_loading) {
      _reload = true;
      return;
    }
    _loading = true;
    try {
      final local = widget.localGames;
      if (local != null && (_refreshLocal || _localFailed)) {
        _refreshLocal = false;
        try {
          final entries = await local();
          if (mounted)
            setState(() {
              _local = entries;
              _localFailed = false;
            });
        } catch (_) {
          if (mounted) setState(() => _localFailed = true);
        }
      }
      final active =
          await widget.chatmail?.activeMatches() ?? const <MatchEntry>[];
      if (mounted) {
        setState(() {
          final game = widget.game;
          _matches = game == null
              ? active
              : active
                    .where((entry) => entry.match.invite.game?.id == game.id)
                    .toList();
          _loaded = true;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _loading = false;
      if (_reload) {
        _reload = false;
        unawaited(_load());
      }
    }
  }

  Future<void> _open(MatchEntry entry) async {
    final (:chat, :match, updated: _) = entry;
    if (_busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OnlineMatchPage(
          chatmail: widget.chatmail!,
          chat: chat.id,
          id: match.invite.id,
          playOnOpen: match.started && !match.conflict,
          prepareGame: widget.prepareGame,
          friendName: chat.name,
          buildChatDock: (close) => FriendConversation.docked(
            chatmail: widget.chatmail!,
            id: chat.id,
            onClose: close,
          ),
        ),
      ),
    );
    await _load();
  }

  Future<void> _end(MatchEntry entry) async {
    if (_busy) return;
    final (:chat, :match, updated: _) = entry;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: const Text('End this game?'),
          content: Text(
            'This ends your online game with ${chat.name} for both players.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Keep game'),
            ),
            FilledButton(
              style: destructiveDialogAction(dialog),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('End game'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      final current = OnlineMatch.replay(
        match.invite.id,
        await widget.chatmail!.matchHistory(chat.id, match.invite.id),
      );
      if (!mounted || current == null || !current.active) return;
      final pending = MatchEvent.parse(current.pending?.text ?? '');
      if (pending?.kind == 'quit' && current.pending?.state == 20) return;
      await widget.chatmail!.send(
        chat.id,
        pending?.kind == 'quit'
            ? pending!.wire
            : current.invite.control('quit', current.nextRevision).wire,
      );
    } catch (_) {
      if (mounted)
        setState(
          () => _actionError =
              'Couldn’t end the game. Check your connection and try again.',
        );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  String _localModeLabel(LocalGameEntry entry) =>
      entry.mode == 'local' ? 'Pass & Play' : 'Single Player';

  Future<void> _quitLocal(LocalGameEntry entry) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: const Text('Quit this game?'),
          content: Text(
            'Your ${_localModeLabel(entry)} progress in ${entry.game.title} will be lost.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Keep game'),
            ),
            FilledButton(
              style: destructiveDialogAction(dialog),
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Quit game'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      const host = MethodChannel('io.zompado.host');
      await host.invokeMethod<void>('discardLocalGameSave', {
        ...entry.game.playerReference,
        'mode': entry.mode,
        'passAndPlay': entry.game.modes.contains('local'),
      });
      if (!mounted) return;
      setState(() => _local = _local.where((saved) => saved != entry).toList());
      _refreshLocal = true;
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() => _actionError = 'Couldn’t quit this game. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resumeLocal(LocalGameEntry entry) async {
    if (_busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GamePlayPage.official(
          game: entry.game,
          title: entry.game.title,
          mode: entry.mode,
          fresh: false,
        ),
      ),
    );
    _refreshLocal = true;
    await _load();
  }

  Widget _matchCard(MatchEntry entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (:chat, :match, updated: _) = entry;
    final pendingQuit =
        MatchEvent.parse(match.pending?.text ?? '')?.kind == 'quit';
    final ending = pendingQuit && match.pending?.state == 20;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.game?.title ?? 'Cats vs Dogs'} with ${chat.name}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              ending
                  ? 'Ending game…'
                  : pendingQuit
                  ? 'Couldn’t end this game.'
                  : match.status,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  if (!match.finished)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: colors.error,
                      ),
                      onPressed: _busy || ending ? null : () => _end(entry),
                      child: Text(pendingQuit ? 'Retry end' : 'End game'),
                    ),
                  FilledButton.tonal(
                    onPressed: _busy ? null : () => _open(entry),
                    child: Text(
                      match.started && !match.conflict
                          ? 'Resume Game'
                          : 'Open game',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('Active', style: theme.textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: 'Close active games',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: _matches.length + 1,
              itemBuilder: (context, index) {
                if (index > 0) return _matchCard(_matches[index - 1]);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.game case final game?)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                        child: Text(
                          game.title,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    for (final entry in _local)
                      Card(
                        child: ListTile(
                          title: Text(entry.game.title),
                          subtitle: Text(_localModeLabel(entry)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton.outlined(
                                tooltip: 'Quit ${_localModeLabel(entry)}',
                                style: IconButton.styleFrom(
                                  shape: const CircleBorder(),
                                  foregroundColor: colors.error,
                                ),
                                icon: const Icon(Icons.close),
                                onPressed: _busy
                                    ? null
                                    : () => _quitLocal(entry),
                              ),
                              const SizedBox(width: 6),
                              IconButton.filledTonal(
                                tooltip: 'Resume ${_localModeLabel(entry)}',
                                style: IconButton.styleFrom(
                                  shape: const CircleBorder(),
                                ),
                                icon: const Icon(
                                  Icons.play_arrow_rounded,
                                  size: 30,
                                ),
                                onPressed: _busy
                                    ? null
                                    : () => _resumeLocal(entry),
                              ),
                            ],
                          ),
                          onTap: _busy ? null : () => _resumeLocal(entry),
                        ),
                      ),
                    if (_localFailed)
                      ListTile(
                        title: const Text(
                          'Couldn’t check games on this device.',
                        ),
                        trailing: TextButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ),
                    if (_failed)
                      ListTile(
                        title: const Text('Couldn’t refresh active games.'),
                        trailing: TextButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      )
                    else if (!_loaded)
                      const LinearProgressIndicator()
                    else if (_matches.isEmpty &&
                        _local.isEmpty &&
                        !_localFailed)
                      const ListTile(
                        title: Text('No active games'),
                        subtitle: Text(
                          'Start one from Play or invite a friend from chat.',
                        ),
                      ),
                    if (_actionError case final error?)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          error,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
