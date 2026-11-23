import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'board.dart';
import 'chatmail.dart';
import 'game_link.dart';
import 'github_distribution.dart';

const matchMarker = 'ZOMPADO_MATCH_V1 ';
const activeMatchLimit = 12;

const inviteLifetime = Duration(days: 7);
const matchIdleTime = Duration(days: 30);

class MatchInviteExpired implements Exception {
  const MatchInviteExpired();
  static const message =
      'This game invitation expired. Send a new invite to play.';
}

typedef MatchEntry = ({FriendChat chat, OnlineMatch match, int updated});
typedef MatchLibrary = ({List<MatchEntry> active, List<MatchEntry> history});
typedef _MatchArchive = ({
  Map<String, String> hidden,
  Map<String, int> reopened,
});

String matchMovedNotice(MatchEntry entry) =>
    'Your game with ${entry.chat.name} was removed from Active Games.';

final _matchWrites = Expando<Future<void>>();

Future<T> _withMatchLock<T>(
  Chatmail chatmail,
  Future<T> Function() operation,
) async {
  while (_matchWrites[chatmail] != null) {
    await _matchWrites[chatmail]!;
  }
  final lock = Completer<void>();
  _matchWrites[chatmail] = lock.future;
  try {
    return await operation();
  } finally {
    _matchWrites[chatmail] = null;
    lock.complete();
  }
}

String _matchKey(MatchEntry entry) =>
    '${entry.chat.id}/${entry.match.invite.id}';

extension OnlineMatchHistory on Chatmail {
  Future<List<MatchEntry>> _knownMatches(DateTime now) async {
    if (!await restore()) return [];
    final folders = await Future.wait([chats(), chats(archived: true)]);
    final byChat = {
      for (final chat in folders.expand((items) => items)) chat.id: chat,
    };
    if (byChat.isEmpty) return [];
    final histories = <(int, String), List<FriendMessage>>{};
    for (final message in await recentMatchMessages(matchMarker)) {
      if (message.info ||
          (!message.outgoing && !message.encrypted) ||
          !byChat.containsKey(message.chat)) {
        continue;
      }
      if (MatchEvent.parse(message.text) case final event?) {
        (histories[(message.chat, event.id)] ??= []).add(message);
      }
    }
    return [
      for (final entry in histories.entries)
        if (OnlineMatch.replay(entry.key.$2, entry.value, now: now)
            case final match?)
          (
            chat: byChat[entry.key.$1]!,
            match: match,
            updated: entry.value
                .map((message) => message.timestamp)
                .reduce(max),
          ),
    ];
  }

  File get _matchArchiveFile =>
      File('${accountsDirectory.path}/game-history.json');

  Future<_MatchArchive> _readMatchArchive() async {
    final file = _matchArchiveFile;
    if (await file.exists()) {
      try {
        final contents = jsonDecode(await file.readAsString());
        if (contents is Map) {
          final hidden = contents['hidden'];
          final reopened = contents['reopened'];
          return (
            hidden: {
              if (hidden is Map)
                for (final entry in hidden.entries)
                  if (entry.key is String && entry.value is String)
                    entry.key as String: entry.value as String,
            },
            reopened: {
              if (reopened is Map)
                for (final entry in reopened.entries)
                  if (entry.key is String && entry.value is int)
                    entry.key as String: entry.value as int,
            },
          );
        }
      } on FormatException {
        // The match boards can still be rebuilt from Chatmail.
      }
    }
    return (hidden: <String, String>{}, reopened: <String, int>{});
  }

  Future<void> _writeMatchArchive(_MatchArchive archive) async {
    final file = _matchArchiveFile;
    await file.parent.create(recursive: true);
    final staging = File('${file.path}.tmp');
    await staging.writeAsString(
      jsonEncode({'hidden': archive.hidden, 'reopened': archive.reopened}),
      flush: true,
    );
    await staging.rename(file.path);
  }

  Future<({MatchLibrary library, MatchEntry? moved})> _arrangeMatches(
    DateTime now, {
    String? keep,
  }) async {
    final all = await _knownMatches(now);
    final archive = await _readMatchArchive();
    final cutoff = now.subtract(matchIdleTime).millisecondsSinceEpoch ~/ 1000;
    int recent(MatchEntry entry) =>
        max(entry.match.lastActivity, archive.reopened[_matchKey(entry)] ?? 0);
    var changed = false;
    final active = <MatchEntry>[];
    final history = <MatchEntry>[];
    for (final entry in all) {
      final key = _matchKey(entry);
      final match = entry.match;
      if (!match.active) {
        if (archive.hidden.remove(key) != null) changed = true;
        if (archive.reopened.remove(key) != null) changed = true;
        history.add(entry);
        continue;
      }
      if (archive.hidden[key] case final marker?
          when marker != match.activityMarker) {
        archive.hidden.remove(key);
        changed = true;
      }
      if (archive.hidden.containsKey(key) ||
          (match.accepted && recent(entry) > 0 && recent(entry) <= cutoff)) {
        history.add(entry);
      } else {
        active.add(entry);
      }
    }

    final occupied =
        active
            .where((entry) => entry.match.mine || entry.match.accepted)
            .toList()
          ..sort((a, b) {
            final byActivity = recent(a).compareTo(recent(b));
            return byActivity != 0
                ? byActivity
                : a.match.activityMessage.compareTo(b.match.activityMessage);
          });
    MatchEntry? moved;
    for (
      var excess = occupied.length - activeMatchLimit;
      excess > 0;
      excess--
    ) {
      final oldest = occupied.firstWhere((entry) => _matchKey(entry) != keep);
      occupied.remove(oldest);
      active.remove(oldest);
      history.add(oldest);
      archive.hidden[_matchKey(oldest)] = oldest.match.activityMarker;
      changed = true;
      moved ??= oldest;
    }
    if (changed) await _writeMatchArchive(archive);
    active.sort((a, b) {
      if (a.match.myTurn != b.match.myTurn) return a.match.myTurn ? -1 : 1;
      return b.updated.compareTo(a.updated);
    });
    history.sort((a, b) => b.updated.compareTo(a.updated));
    return (library: (active: active, history: history), moved: moved);
  }

  Future<MatchLibrary> matchLibrary({DateTime? now}) => _withMatchLock(
    this,
    () async => (await _arrangeMatches(now ?? DateTime.now())).library,
  );

  Future<List<MatchEntry>> activeMatches() async =>
      (await matchLibrary()).active;

  Future<void> checkInviteExpiry(int chat, String id) async {
    final match = OnlineMatch.replay(id, await matchHistory(chat, id));
    if (match?.expired == true) throw const MatchInviteExpired();
  }

  Future<MatchEntry?> sendMatchOpening(int chat, MatchEvent event) =>
      _withMatchLock(this, () async {
        await checkInviteExpiry(chat, event.id);
        await send(chat, event.wire);
        try {
          return (await _arrangeMatches(
            DateTime.now(),
            keep: '$chat/${event.id}',
          )).moved;
        } catch (_) {
          // The game message was sent. Refreshing the library can retry the move to History.
          return null;
        }
      });
}

class MatchEvent {
  MatchEvent._(
    this.id,
    this.kind, {
    this.game,
    this.previous,
    this.column,
    this.payload,
    this.turnProtocol = false,
    this.outcome,
    this.revision,
    this.rematchOf,
    this.series = false,
    this.round = 1,
  });

  factory MatchEvent.invite(
    GameLink game, {
    String? rematchOf,
    bool turnProtocol = false,
  }) {
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return MatchEvent._(
      id,
      'invite',
      game: game,
      rematchOf: rematchOf,
      series: !turnProtocol && game.build >= 11,
      turnProtocol: turnProtocol,
    );
  }

  final String id;
  final String kind;
  final GameLink? game;
  final String? previous, rematchOf;
  final int? column, revision, outcome;
  final String? payload;
  final bool turnProtocol;
  final bool series;
  final int round;

  static bool supportsGame(GameRelease game) =>
      game.modes.contains('online') &&
      (game.onlineProtocol == 'turns-v1' || game.id == 'drop-four');

  // A bounded ASCII move can encode JSON, text, or a compact game-specific token.
  static bool validPayload(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(value);

  MatchEvent accept() => MatchEvent._(id, 'accept', series: series);
  MatchEvent decline() => MatchEvent._(id, 'decline');
  MatchEvent preparing() => MatchEvent._(id, 'preparing');
  MatchEvent control(String kind, int revision) =>
      MatchEvent._(id, kind, revision: revision);
  MatchEvent move(String previous, int column, {int round = 1}) => MatchEvent._(
    id,
    'move',
    previous: previous,
    column: column,
    round: round,
  );
  MatchEvent turn(String previous, String payload, {int? outcome}) =>
      MatchEvent._(
        id,
        'turn',
        previous: previous,
        payload: payload,
        outcome: outcome,
      );
  MatchEvent nextRound(int completedRound, String moves) =>
      MatchEvent._(id, 'next', round: completedRound, previous: moves);

  String get wire {
    final data = {
      'id': id,
      'type': kind,
      if (game case final link?) 'game': link.toMatchWire(),
      if (rematchOf != null) 'rematchOf': rematchOf,
      if (previous != null) 'previous': previous,
      if (column != null) 'column': column,
      if (payload != null) 'payload': payload,
      if (outcome != null) 'outcome': outcome,
      if (turnProtocol) 'protocol': 'turns-v1',
      if (revision != null) 'rev': revision,
      if (series) 'series': true,
      if (kind == 'next' || round > 1) 'round': round,
    };
    return '$matchMarker${jsonEncode(data)}';
  }

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
              final turnProtocol = data['protocol'] == 'turns-v1';
              if (game != null && (turnProtocol || game.id == 'drop-four')) {
                final rematchOf = data['rematchOf'];
                return MatchEvent._(
                  id,
                  'invite',
                  game: game,
                  series:
                      !turnProtocol &&
                      game.build >= 11 &&
                      data['series'] == true,
                  turnProtocol: turnProtocol,
                  rematchOf:
                      rematchOf is String &&
                          rematchOf != id &&
                          RegExp(r'^[a-f0-9]{32}$').hasMatch(rematchOf)
                      ? rematchOf
                      : null,
                );
              }
            }
          case 'accept':
            return MatchEvent._(id, 'accept', series: data['series'] == true);
          case 'next':
            final round = data['round'];
            final moves = data['previous'];
            if (round is int &&
                round >= 1 &&
                round <= 0x7fffffff &&
                moves is String &&
                RegExp(r'^[0-6]{7,42}$').hasMatch(moves)) {
              return MatchEvent._(id, 'next', round: round, previous: moves);
            }
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
          case 'turn':
            final previous = data['previous'];
            final payload = data['payload'];
            final outcome = data['outcome'];
            if (previous is String &&
                RegExp(r'^[a-f0-9]{64}$').hasMatch(previous) &&
                payload is String &&
                validPayload(payload) &&
                (outcome == null ||
                    (outcome is int && outcome >= 0 && outcome <= 2))) {
              return MatchEvent._(
                id,
                'turn',
                previous: previous,
                payload: payload,
                outcome: outcome as int?,
              );
            }
          case 'move':
            final previous = data['previous'];
            final column = data['column'];
            final round = data['round'] ?? 1;
            if (round is int &&
                round >= 1 &&
                round <= 0x7fffffff &&
                previous is String &&
                RegExp(r'^[0-6]{0,41}$').hasMatch(previous) &&
                column is int &&
                column >= 0 &&
                column < 7) {
              return MatchEvent._(
                id,
                'move',
                previous: previous,
                column: column,
                round: round,
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
  Board board = Board();
  String moves = '';
  final turnHistory = <String>[];
  String turnHead = '0' * 64;
  int? turnOutcome;
  int get turn => invite.turnProtocol ? turnHistory.length % 2 + 1 : board.turn;
  int get winner => invite.turnProtocol ? turnOutcome ?? 0 : board.winner;

  String sdkSnapshot({required bool canMove}) =>
      '${mine ? 1 : 2}:${canMove ? 1 : 0}:${turnHistory.join(",")}';
  bool series = false;
  int round = 1;
  final scores = [0, 0];
  bool accepted = false;
  bool started = false;
  bool declined = false;
  bool preparing = false;
  bool expired = false;
  int lastActivity = 0;
  int activityMessage = 0;
  String get activityMarker => '$lastActivity/$activityMessage';

  void _recordActivity(FriendMessage message) {
    if (message.timestamp < lastActivity ||
        (message.timestamp == lastActivity && message.id <= activityMessage)) {
      return;
    }
    lastActivity = message.timestamp;
    activityMessage = message.id;
  }

  MatchEvent? localControl, remoteControl;

  bool get pausedByMe => localControl?.kind == 'pause';
  bool get pausedByFriend => remoteControl?.kind == 'pause';
  bool get paused => pausedByMe || pausedByFriend;
  bool get quit =>
      localControl?.kind == 'quit' || remoteControl?.kind == 'quit';
  int get nextRevision => (localControl?.revision ?? 0) + 1;
  bool conflict = false;
  FriendMessage? pending;

  bool get boardComplete => invite.turnProtocol
      ? turnOutcome != null
      : board.winner != 0 || board.full;
  bool get finished =>
      expired ||
      declined ||
      quit ||
      (series ? scores.contains(3) : boardComplete);
  bool get active =>
      !finished || (pending != null && !expired && !declined && !quit);
  bool get myTurn =>
      accepted &&
      started &&
      !conflict &&
      !finished &&
      !boardComplete &&
      !paused &&
      pending == null &&
      (turn == 1) == mine;

  String get status {
    if (quit) return 'Match ended.';
    if (expired) return 'Invite expired.';
    if (conflict) return 'Conflicting turns. Start a new match.';
    if (pending?.state == 20) return 'Sending match update…';
    if (pending?.state == 24) return 'Couldn’t send this match update.';
    if (declined) return 'Invitation declined.';
    if (winner != 0) {
      final youWon = (winner == 1) == mine;
      if (series) {
        return finished
            ? (youWon ? 'You won the series!' : 'Your friend won the series.')
            : (youWon ? 'You won this round!' : 'Your friend won this round.');
      }
      return youWon ? 'You won!' : 'Your friend won.';
    }
    if (boardComplete) return 'Draw.';
    if (pausedByMe) return 'You paused the game.';
    if (pausedByFriend) return 'Your friend paused the game.';
    if (!accepted && preparing) return 'Getting the game ready…';
    if (!accepted) {
      return mine
          ? 'Waiting for your friend to accept.'
          : 'Your friend invited you to a match.';
    }
    if (!started) {
      return mine ? 'Ready to start.' : 'Waiting for your friend to start.';
    }
    return myTurn ? 'Your turn' : 'Your friend’s turn';
  }

  static OnlineMatch? replay(
    String id,
    List<FriendMessage> records, {
    DateTime? now,
  }) {
    final events = [
      for (final m in records)
        if (!m.info && (m.outgoing || m.encrypted))
          if (MatchEvent.parse(m.text) case final MatchEvent e when e.id == id)
            (event: e, message: m),
    ];
    final invitations = events.where((r) => r.event.kind == 'invite').toList();
    if (invitations.isEmpty) return null;
    final first = invitations.first;
    final match = OnlineMatch._(first.event, first.message.outgoing)
      .._recordActivity(first.message);
    if (invitations.any(
      (r) =>
          r.message.outgoing != match.mine ||
          r.event.game.toString() != first.event.game.toString() ||
          r.event.rematchOf != first.event.rematchOf ||
          r.event.series != first.event.series ||
          r.event.turnProtocol != first.event.turnProtocol,
    )) {
      match.conflict = true;
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
        .toList();
    match.series =
        match.invite.series &&
        accepts.any(
          (record) => record.event.series && record.message.delivery == null,
        );
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
    match.accepted = accepts.isNotEmpty;
    if (match.accepted) {
      match.pending = pendingFor(
        accepts.map((record) => record.message).toList(),
      );
      for (final record in accepts) {
        if (record.message.delivery == null)
          match._recordActivity(record.message);
      }
    }
    if (!accepts.any((record) => record.message.delivery == null)) {
      final dates = invitations
          .map((record) => record.message.timestamp)
          .where((timestamp) => timestamp > 0);
      if (!match.declined && dates.isNotEmpty) {
        final cutoff =
            (now ?? DateTime.now())
                .subtract(inviteLifetime)
                .millisecondsSinceEpoch ~/
            1000;
        match.expired = dates.reduce(min) <= cutoff;
      }
    }
    if (match.invite.turnProtocol && match.accepted && !match.conflict) {
      final byHead =
          <String, List<({MatchEvent event, FriendMessage message})>>{};
      for (final record in events) {
        if (record.event.kind == 'turn') {
          (byHead[record.event.previous!] ??= []).add(record);
        }
      }
      while (!match.boardComplete &&
          match.pending == null &&
          match.turnHistory.length < 512) {
        final outgoing = (match.turn == 1) == match.mine;
        final candidates = byHead[match.turnHead]
            ?.where((record) => record.message.outgoing == outgoing)
            .toList();
        if (candidates == null || candidates.isEmpty) break;
        final event = candidates.first.event;
        if (candidates.any(
          (record) =>
              record.event.payload != event.payload ||
              record.event.outcome != event.outcome,
        )) {
          match.conflict = true;
          break;
        }
        match.pending = pendingFor(candidates.map((r) => r.message).toList());
        if (match.pending != null) break;
        for (final record in candidates) {
          if (record.message.delivery == null)
            match._recordActivity(record.message);
        }
        match.turnHistory.add(event.payload!);
        match.turnOutcome = event.outcome;
        match.turnHead = sha256.convert(utf8.encode(event.wire)).toString();
      }
      if (match.turnHistory.length == 512 && !match.boardComplete) {
        match.turnOutcome = 0;
      }
    }
    while (!match.invite.turnProtocol &&
        match.accepted &&
        !match.finished &&
        !match.conflict) {
      if (match.boardComplete) {
        if (!match.series || match.pending != null) break;
        final winner = match.board.winner;
        if (winner != 0) match.scores[winner - 1]++;
        if (match.finished) break;
        final next = [
          for (final record in events)
            if (record.event.kind == 'next' &&
                record.event.round == match.round &&
                record.event.previous == match.moves)
              record.message,
        ];
        if (next.isEmpty) break;
        match.pending = pendingFor(next);
        if (match.pending != null) break;
        for (final message in next) {
          if (message.delivery == null) match._recordActivity(message);
        }
        match.round++;
        match.board = Board();
        match.moves = '';
      }
      final ownTurn = (match.board.turn == 1) == match.mine;
      final candidates = events
          .where(
            (r) =>
                r.event.kind == 'move' &&
                r.event.round == match.round &&
                r.event.previous == match.moves &&
                r.message.outgoing == ownTurn &&
                match.board.landing(r.event.column!) >= 0,
          )
          .toList();
      if (candidates.isEmpty) break;
      final column = candidates.first.event.column!;
      if (candidates.any((r) => r.event.column != column)) {
        match.conflict = true;
        break;
      }
      for (final candidate in candidates) {
        if (candidate.message.delivery == null)
          match._recordActivity(candidate.message);
      }
      match.board.drop(column);
      match.moves += '$column';
      match.pending = pendingFor(candidates.map((r) => r.message).toList());
    }
    // An inviter can send a resume before the first move to start both boards.
    // Older clients also understand resume, and their first move starts the match.
    match.started =
        match.round > 1 ||
        match.moves.isNotEmpty ||
        match.turnHistory.isNotEmpty;
    if (match.accepted && !match.started) {
      final starts = [
        for (final record in events)
          if (record.event.kind == 'resume' &&
              record.message.outgoing == match.mine)
            record.message,
      ];
      if (starts.isNotEmpty) {
        final pendingStart = pendingFor(starts);
        match.pending ??= pendingStart;
        match.started = pendingStart == null;
        for (final start in starts) {
          if (start.delivery == null) match._recordActivity(start);
        }
      }
    }
    // Each player has a separate control revision. Replay is independent of
    // the order in which two devices receive simultaneous pause updates.
    FriendMessage? pendingControl;
    var pendingControlRevision = 0;
    var deliveredControlRevision = 0;
    for (final record in events) {
      final (:event, :message) = record;
      final revision = event.revision;
      if (revision == null || (!match.accepted && event.kind != 'quit'))
        continue;
      final own = message.outgoing;
      if (own && event.kind != 'quit') {
        if (message.delivery == null) {
          deliveredControlRevision = max(deliveredControlRevision, revision);
        } else if (revision > pendingControlRevision ||
            (revision == pendingControlRevision && message.state == 20)) {
          pendingControl = message;
          pendingControlRevision = revision;
        }
      }
      if (message.state == 24 ||
          (own && event.kind == 'quit' && message.state == 20)) {
        continue;
      }
      final previous = own ? match.localControl : match.remoteControl;
      if (previous?.kind == 'quit' ||
          (event.kind != 'quit' && (previous?.revision ?? 0) >= revision))
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
      if (match.started && pendingControlRevision > deliveredControlRevision) {
        match.pending ??= pendingControl;
      }
    }
    return match;
  }
}
