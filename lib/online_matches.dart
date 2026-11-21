import 'dart:async';

import 'package:flutter/material.dart';

import 'chatmail.dart';
import 'friends.dart';
import 'game_link.dart';
import 'github_distribution.dart';
import 'online_match.dart';
import 'online_match_page.dart';

String localGameModeLabel(String mode) =>
    mode == 'local' ? 'Pass & Play' : 'Single Player';

Future<List<MatchEntry>> resumableMatches(
  Chatmail chatmail,
  GameRelease game,
) async => (await chatmail.activeMatches()).where((entry) {
  final match = entry.match;
  final pending = match.pending;
  return match.invite.game?.id == game.id &&
      match.started &&
      !match.finished &&
      !(pending?.state == 20 &&
          MatchEvent.parse(pending?.text ?? '')?.kind == 'quit');
}).toList();

Future<String?> showActiveGames(
  BuildContext context, {
  required Chatmail? chatmail,
  required Future<GameRelease?> Function(GameLink) prepareGame,
  GameRelease? game,
  List<String> localModes = const [],
  bool resumeOnly = false,
}) => showModalBottomSheet<String>(
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
      localModes: localModes,
      resumeOnly: resumeOnly,
    ),
  ),
);

class _ActiveGamesSheet extends StatefulWidget {
  const _ActiveGamesSheet({
    required this.chatmail,
    required this.prepareGame,
    required this.game,
    required this.localModes,
    required this.resumeOnly,
  });

  final Chatmail? chatmail;
  final Future<GameRelease?> Function(GameLink) prepareGame;
  final GameRelease? game;
  final List<String> localModes;
  final bool resumeOnly;

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
    if (state == AppLifecycleState.resumed) unawaited(_load());
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
      final chatmail = widget.chatmail;
      final active = chatmail == null
          ? const <MatchEntry>[]
          : widget.resumeOnly
          ? await resumableMatches(chatmail, widget.game!)
          : await chatmail.activeMatches();
      if (mounted) {
        setState(() {
          _matches = active;
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
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialog).colorScheme.error,
                foregroundColor: Theme.of(dialog).colorScheme.onError,
              ),
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
                  child: Text(
                    widget.resumeOnly ? 'Resume a game' : 'Active Games',
                    style: theme.textTheme.titleLarge,
                  ),
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
                    for (final mode in widget.localModes)
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: Icon(
                            mode == 'local'
                                ? Icons.people_outline
                                : Icons.person_outline,
                          ),
                          title: Text(localGameModeLabel(mode)),
                          subtitle: const Text('Resume saved game'),
                          trailing: const Icon(Icons.play_arrow),
                          onTap: () => Navigator.pop(context, mode),
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
                    else if (_matches.isEmpty && widget.localModes.isEmpty)
                      ListTile(
                        title: Text(
                          widget.resumeOnly
                              ? 'No unfinished games'
                              : 'No active online games',
                        ),
                        subtitle: const Text('Start a new game from Play.'),
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
