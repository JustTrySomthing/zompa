import 'dart:async';

import 'package:flutter/material.dart';

import 'chatmail.dart';
import 'friends.dart';
import 'game_link.dart';
import 'online_match.dart';
import 'online_match_page.dart';

class YourTurn extends StatefulWidget {
  const YourTurn({
    super.key,
    required this.chatmail,
    required this.prepareGame,
  });

  final Chatmail chatmail;
  final Future<bool> Function(GameLink) prepareGame;

  @override
  State<YourTurn> createState() => _YourTurnState();
}

class _YourTurnState extends State<YourTurn> with WidgetsBindingObserver {
  StreamSubscription<void>? _events;
  Timer? _timer;
  bool _loading = false;
  bool _reload = false;
  List<(FriendChat, String)> _turns = [];

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
      if (!await widget.chatmail.restore() || !mounted) return;
      final chats = {
        for (final chat in await widget.chatmail.chats()) chat.id: chat,
      };
      if (!mounted) return;
      if (chats.isEmpty) {
        if (_turns.isNotEmpty) setState(_turns.clear);
        return;
      }
      final recent = await widget.chatmail.recentMatchMessages(matchMarker);
      final matches = <(int, String)>{};
      for (final message in recent) {
        if (message.info ||
            (!message.outgoing && !message.encrypted) ||
            !chats.containsKey(message.chat))
          continue;
        final event = MatchEvent.parse(message.text);
        if (event != null) matches.add((message.chat, event.id));
      }

      final turns = <(FriendChat, String)>[];
      for (final (chat, id) in matches) {
        if (!mounted) return;
        final history = await widget.chatmail.matchHistory(chat, id);
        if (OnlineMatch.replay(id, history)?.myTurn == true) {
          turns.add((chats[chat]!, id));
        }
      }
      if (mounted) setState(() => _turns = turns);
    } catch (_) {
      if (mounted && _turns.isNotEmpty) setState(_turns.clear);
    } finally {
      _loading = false;
      if (_reload) {
        _reload = false;
        unawaited(_load());
      }
    }
  }

  Future<void> _open(FriendChat chat, String id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OnlineMatchPage(
          chatmail: widget.chatmail,
          chat: chat.id,
          id: id,
          prepareGame: widget.prepareGame,
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
    if (_turns.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              'Your turn',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final (chat, id) in _turns)
            ListTile(
              leading: const Icon(Icons.sports_esports_outlined),
              title: const Text('Drop Four'),
              subtitle: Text(chat.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(chat, id),
            ),
        ],
      ),
    );
  }
}
