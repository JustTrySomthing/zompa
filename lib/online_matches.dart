import 'dart:async';

import 'package:flutter/material.dart';

import 'chatmail.dart';
import 'friends.dart';
import 'game_link.dart';
import 'github_distribution.dart';
import 'online_match.dart';
import 'online_match_page.dart';

class OnlineMatches extends StatefulWidget {
  const OnlineMatches({
    super.key,
    required this.chatmail,
    required this.prepareGame,
    this.onOpenChats,
  });

  final Chatmail chatmail;
  final Future<GameRelease?> Function(GameLink) prepareGame;
  final VoidCallback? onOpenChats;

  @override
  State<OnlineMatches> createState() => _OnlineMatchesState();
}

class _OnlineMatchesState extends State<OnlineMatches>
    with WidgetsBindingObserver {
  StreamSubscription<void>? _events;
  Timer? _timer;
  bool _loading = false;
  bool _reload = false;
  List<({FriendChat chat, OnlineMatch match})> _matches = [];
  bool _loaded = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _events = widget.chatmail.changes.listen((_) {
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
      final ready = await widget.chatmail.restore();
      final chats = {
        if (ready)
          for (final chat in await widget.chatmail.chats()) chat.id: chat,
      };
      if (!mounted) return;
      final records = chats.isEmpty
          ? const <FriendMessage>[]
          : await widget.chatmail.recentMatchMessages(matchMarker);
      final histories = <(int, String), List<FriendMessage>>{};
      for (final message in records) {
        if (!chats.containsKey(message.chat)) continue;
        if (MatchEvent.parse(message.text) case final event?) {
          (histories[(message.chat, event.id)] ??= []).add(message);
        }
      }
      final active = [
        for (final entry in histories.entries)
          if (OnlineMatch.replay(entry.key.$2, entry.value) case final match?
              when match.active)
            (chat: chats[entry.key.$1]!, match: match),
      ];
      if (mounted) {
        setState(() {
          _matches = [
            ...active.where((entry) => entry.match.myTurn),
            ...active.where((entry) => !entry.match.myTurn),
          ];
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

  Future<void> _open(FriendChat chat, OnlineMatch match) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OnlineMatchPage(
          chatmail: widget.chatmail,
          chat: chat.id,
          id: match.invite.id,
          playOnOpen: match.started && !match.conflict,
          prepareGame: widget.prepareGame,
          friendName: chat.name,
          buildChatDock: (close) => FriendConversation.docked(
            chatmail: widget.chatmail,
            id: chat.id,
            onClose: close,
          ),
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final standalone = widget.onOpenChats != null;
    if (_matches.isEmpty && !standalone) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!standalone)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(
                'Online matches',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          if (_failed)
            ListTile(
              title: const Text('Couldn’t refresh your matches.'),
              trailing: TextButton(
                onPressed: _load,
                child: const Text('Retry'),
              ),
            )
          else if (!_loaded)
            const LinearProgressIndicator()
          else if (_matches.isEmpty)
            ListTile(
              title: const Text('No active matches'),
              subtitle: const Text(
                'Open a friend’s chat and tap the game controller to send a match invite.',
              ),
              trailing: TextButton(
                onPressed: widget.onOpenChats,
                child: const Text('Open Chats'),
              ),
            ),
          for (final entry in _matches)
            ListTile(
              leading: Icon(
                entry.match.myTurn
                    ? Icons.sports_esports
                    : Icons.sports_esports_outlined,
              ),
              title: Text('Cats vs Dogs with ${entry.chat.name}'),
              subtitle: Text(entry.match.status),
              trailing: entry.match.started && !entry.match.conflict
                  ? FilledButton.tonal(
                      onPressed: () => _open(entry.chat, entry.match),
                      child: const Text('Resume Game'),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: () => _open(entry.chat, entry.match),
            ),
        ],
      ),
    );
  }
}
