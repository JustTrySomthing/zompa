import 'dart:convert';
import 'dart:math';

import 'board.dart';
import 'chatmail.dart';
import 'game_link.dart';

const matchMarker = 'ZOMPADO_MATCH_V1 ';

class MatchEvent {
  MatchEvent._(
    this.id,
    this.kind, {
    this.game,
    this.previous,
    this.column,
    this.revision,
  });

  factory MatchEvent.invite(GameLink game) {
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return MatchEvent._(id, 'invite', game: game);
  }

  final String id;
  final String kind;
  final GameLink? game;
  final String? previous;
  final int? column, revision;

  MatchEvent accept() => MatchEvent._(id, 'accept');
  MatchEvent decline() => MatchEvent._(id, 'decline');
  MatchEvent preparing() => MatchEvent._(id, 'preparing');
  MatchEvent control(String kind, int revision) =>
      MatchEvent._(id, kind, revision: revision);
  MatchEvent move(String previous, int column) =>
      MatchEvent._(id, 'move', previous: previous, column: column);

  String get wire =>
      '$matchMarker${jsonEncode({'id': id, 'type': kind, if (game != null) 'game': game.toString(), if (previous != null) 'previous': previous, if (column != null) 'column': column, if (revision != null) 'rev': revision})}';

  static MatchEvent? parse(String text) {
    if (!text.startsWith(matchMarker) || text.length > 800) return null;
    try {
      if (jsonDecode(text.substring(matchMarker.length))
          case final Map<String, dynamic> data) {
        final id = data['id'];
        if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id))
          return null;
        switch (data['type']) {
          case 'invite':
            if (data['game'] case final String link) {
              final game = GameLink.parse(link);
              if (game != null && game.id == 'drop-four')
                return MatchEvent._(id, 'invite', game: game);
            }
          case 'accept':
          case 'preparing':
          case 'decline':
            return MatchEvent._(id, data['type'] as String);
          case 'pause':
          case 'resume':
          case 'quit':
            final revision = data['rev'];
            if (revision is int && revision >= 1 && revision <= 0x7fffffff) {
              return MatchEvent._(
                id,
                data['type'] as String,
                revision: revision,
              );
            }
          case 'move':
            final previous = data['previous'];
            final column = data['column'];
            if (previous is String &&
                RegExp(r'^[0-6]{0,41}$').hasMatch(previous) &&
                column is int &&
                column >= 0 &&
                column < 7) {
              return MatchEvent._(
                id,
                'move',
                previous: previous,
                column: column,
              );
            }
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

class OnlineMatch {
  OnlineMatch._(this.invite, this.mine);

  final MatchEvent invite;
  final bool mine;
  final board = Board();
  String moves = '';
  bool accepted = false;
  bool started = false;
  bool declined = false;
  bool preparing = false;
  MatchEvent? localControl, remoteControl;

  bool get pausedByMe => localControl?.kind == 'pause';
  bool get pausedByFriend => remoteControl?.kind == 'pause';
  bool get paused => pausedByMe || pausedByFriend;
  bool get quit =>
      localControl?.kind == 'quit' || remoteControl?.kind == 'quit';
  int get nextRevision => (localControl?.revision ?? 0) + 1;
  bool conflict = false;
  FriendMessage? pending;

  bool get finished => declined || quit || board.winner != 0 || board.full;
  bool get active => !finished || (pending != null && !declined && !quit);
  bool get myTurn =>
      accepted &&
      started &&
      !conflict &&
      !finished &&
      !paused &&
      pending == null &&
      (board.turn == 1) == mine;

  String get status {
    if (conflict) return 'Conflicting turns. Start a new match.';
    if (pending?.state == 20) return 'Sending match update…';
    if (pending?.state == 24) return 'Couldn’t send this match update.';
    if (declined) return 'Invitation declined.';
    if (quit) return 'Match ended.';
    if (pausedByMe) return 'You paused the game.';
    if (pausedByFriend) return 'Your friend paused the game.';
    if (!accepted && preparing) return 'Getting the game ready…';
    if (!accepted) {
      return mine
          ? 'Waiting for your friend to accept.'
          : 'Your friend invited you to a match.';
    }
    if (board.winner != 0) {
      return (board.winner == 1) == mine ? 'You won!' : 'Your friend won.';
    }
    if (board.full) return 'Draw.';
    if (!started) {
      return mine ? 'Ready to start.' : 'Waiting for your friend to start.';
    }
    return myTurn ? 'Your turn' : 'Your friend’s turn';
  }

  static OnlineMatch? replay(String id, List<FriendMessage> records) {
    final events = [
      for (final m in records)
        if (!m.info && (m.outgoing || m.encrypted))
          if (MatchEvent.parse(m.text) case final MatchEvent e when e.id == id)
            (event: e, message: m),
    ];
    final invitations = events.where((r) => r.event.kind == 'invite').toList();
    if (invitations.isEmpty) return null;
    final first = invitations.first;
    final match = OnlineMatch._(first.event, first.message.outgoing);
    if (invitations.any(
      (r) =>
          r.message.outgoing != match.mine ||
          r.event.game.toString() != first.event.game.toString(),
    )) {
      return match..conflict = true;
    }
    FriendMessage? pendingFor(List<FriendMessage> messages) {
      if (messages.any((m) => !m.outgoing || m.delivery == null)) return null;
      return messages.where((m) => m.state == 20).firstOrNull ??
          messages.lastOrNull;
    }

    match.pending = pendingFor(invitations.map((r) => r.message).toList());
    final accepts = events
        .where(
          (r) => r.event.kind == 'accept' && r.message.outgoing != match.mine,
        )
        .map((r) => r.message)
        .toList();
    final replies = events.where(
      (record) =>
          record.message.outgoing != match.mine &&
          (record.event.kind == 'decline' ||
              record.event.kind == 'preparing') &&
          record.message.state != 24,
    );
    match.preparing = replies.any((record) => record.event.kind == 'preparing');
    match.declined =
        accepts.isEmpty &&
        replies.any((record) => record.event.kind == 'decline');
    if (accepts.isEmpty) return match;
    match.accepted = true;
    match.pending = pendingFor(accepts);
    while (!match.finished) {
      final ownTurn = (match.board.turn == 1) == match.mine;
      final candidates = events
          .where(
            (r) =>
                r.event.kind == 'move' &&
                r.event.previous == match.moves &&
                r.message.outgoing == ownTurn &&
                match.board.landing(r.event.column!) >= 0,
          )
          .toList();
      if (candidates.isEmpty) break;
      final column = candidates.first.event.column!;
      if (candidates.any((r) => r.event.column != column))
        return match..conflict = true;
      match.board.drop(column);
      match.moves += '$column';
      match.pending = pendingFor(candidates.map((r) => r.message).toList());
    }
    // An inviter can send a resume before the first move to start both boards.
    // Older clients also understand resume, and their first move starts the match.
    match.started = match.moves.isNotEmpty;
    if (!match.started) {
      final starts = [
        for (final record in events)
          if (record.event.kind == 'resume' &&
              record.message.outgoing == match.mine)
            record.message,
      ];
      if (starts.isNotEmpty) {
        match.pending = pendingFor(starts);
        match.started = match.pending == null;
      }
    }
    // Each player has a separate control revision. Replay is independent of
    // the order in which two devices receive simultaneous pause updates.
    for (final record in events) {
      final event = record.event;
      if (event.revision == null || record.message.state == 24) continue;
      final own = record.message.outgoing;
      if (own && event.kind == 'quit' && record.message.state == 20) continue;
      final previous = own ? match.localControl : match.remoteControl;
      if (previous?.kind == 'quit' ||
          (event.kind != 'quit' &&
              (previous?.revision ?? 0) >= event.revision!))
        continue;
      if (own) {
        match.localControl = event;
      } else {
        match.remoteControl = event;
      }
    }
    if (match.quit) {
      match.pending = null;
    } else if (!match.finished) {
      final pendingQuits = [
        for (final record in events)
          if (record.event.kind == 'quit' && record.message.outgoing)
            record.message,
      ];
      if (pendingQuits.isNotEmpty) match.pending = pendingFor(pendingQuits);
    }
    return match;
  }
}
