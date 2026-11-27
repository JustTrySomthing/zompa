import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../lib/chatmail.dart';
import '../lib/game_link.dart';
import '../lib/online_match.dart';

void main() {
  final game = GameLink.parse(
    'https://justtrysomthing.github.io/zompa/game/'
    '?id=drop-four&build=5&sha=${'a' * 64}',
  )!;
  final invite = MatchEvent.invite(game);
  final start = invite.control('resume', 1);

  FriendMessage message(
    MatchEvent event, {
    required bool outgoing,
    int? state,
    int timestamp = 0,
  }) => FriendMessage.fromJson({
    'id': 1,
    'state': state ?? (outgoing ? 26 : 10),
    'text': event.wire,
    'fromId': outgoing ? 1 : 2,
    'showPadlock': true,
    'timestamp': timestamp,
  });

  OnlineMatch replay(List<FriendMessage> updates, {bool mine = true}) =>
      OnlineMatch.replay(invite.id, [
        message(invite, outgoing: mine),
        message(invite.accept(), outgoing: !mine),
        ...updates,
      ])!;

  void check(bool passed, String scenario) {
    if (!passed) throw StateError(scenario);
  }

  final lobby = replay([]);
  check(lobby.accepted && !lobby.myTurn, 'An accepted lobby has no turn yet');

  final sentAt = DateTime.utc(2026, 1, 1);
  final datedInvite = message(
    invite,
    outgoing: false,
    timestamp: sentAt.millisecondsSinceEpoch ~/ 1000,
  );
  final deadline = sentAt.add(inviteLifetime);
  check(
    OnlineMatch.replay(invite.id, [
      datedInvite,
    ], now: deadline.subtract(const Duration(seconds: 1)))!.active,
    'An unanswered invitation stays active up to the expiry deadline',
  );
  check(
    OnlineMatch.replay(invite.id, [datedInvite], now: deadline)!.expired,
    'An unanswered invitation expires exactly seven days after sending',
  );
  check(
    OnlineMatch.replay(invite.id, [
      datedInvite,
      message(invite.accept(), outgoing: true, state: 24),
    ], now: deadline)!.expired,
    'A failed acceptance does not extend the invitation deadline',
  );
  check(
    !OnlineMatch.replay(invite.id, [
      datedInvite,
      message(invite.accept(), outgoing: true),
    ], now: deadline)!.expired,
    'A previously accepted invitation retains the match',
  );

  final queued = replay([message(start, outgoing: true, state: 20)]);
  check(
    !queued.started && queued.pending?.state == 20 && !queued.myTurn,
    'The inviter waits for the queued start',
  );
  final failed = replay([message(start, outgoing: true, state: 24)]);
  check(
    !failed.started && failed.pending?.text == start.wire,
    'An undelivered start can be retried',
  );

  final sent = replay([
    message(start, outgoing: true, state: 24),
    message(start, outgoing: true),
  ]);
  check(
    sent.started && sent.pending == null && sent.myTurn,
    'A successful retry opens the board with the inviter’s turn',
  );
  final received = replay([message(start, outgoing: false)], mine: false);
  check(
    received.started && !received.myTurn,
    'The recipient opens the board without taking the first turn',
  );
  check(
    !replay([message(start, outgoing: true)], mine: false).started,
    'A recipient resume does not start the match',
  );

  final resumed = replay([
    message(invite.move('', 3), outgoing: false),
  ], mine: false);
  check(
    resumed.started && resumed.moves == '3' && resumed.myTurn,
    'An older match with no start message replays its first move',
  );
  final quit = invite.control('quit', 2);
  final unanswered = OnlineMatch.replay(invite.id, [
    message(invite, outgoing: true),
    message(quit, outgoing: true, state: 24),
  ])!;
  check(
    unanswered.active &&
        !unanswered.accepted &&
        unanswered.pending?.state == 24,
    'An unanswered invitation can retry a failed cancellation',
  );
  final canceled = OnlineMatch.replay(invite.id, [
    message(invite, outgoing: false),
    message(quit, outgoing: false),
  ])!;
  check(
    canceled.quit && !canceled.active,
    'A canceled invitation disappears for the recipient before acceptance',
  );
  final queuedQuit = replay([
    message(start, outgoing: true),
    message(quit, outgoing: true, state: 20),
  ]);
  check(
    !queuedQuit.finished && queuedQuit.pending?.state == 20,
    'A queued quit keeps the match available until delivery',
  );
  final failedQuit = replay([
    message(start, outgoing: true),
    message(quit, outgoing: true, state: 24),
  ]);
  check(
    !failedQuit.finished && failedQuit.pending?.text == quit.wire,
    'A failed quit remains available to retry',
  );
  final retriedQuit = replay([
    message(start, outgoing: true),
    message(quit, outgoing: true, state: 24),
    message(quit, outgoing: true),
  ]);
  check(
    retriedQuit.finished && retriedQuit.pending == null,
    'A delivered retry ends the match',
  );
  final remoteQuit = replay([
    message(start, outgoing: true),
    message(quit, outgoing: true, state: 20),
    message(invite.control('quit', 1), outgoing: false),
  ]);
  check(
    remoteQuit.finished && remoteQuit.status == 'Match ended.',
    'A confirmed remote quit overrides a queued local quit',
  );
  const winningMoves = '0101010';
  final pendingWin = [
    for (var i = 0; i < winningMoves.length; i++)
      message(
        invite.move(winningMoves.substring(0, i), int.parse(winningMoves[i])),
        outgoing: i.isEven,
        state: i == winningMoves.length - 1 ? 24 : null,
      ),
  ];
  final failedWin = replay(pendingWin);
  check(
    failedWin.finished && failedWin.active && failedWin.pending?.state == 24,
    'A failed winning move keeps the match available to reopen and retry',
  );
  final deliveredWin = replay([
    ...pendingWin,
    message(invite.move('010101', 0), outgoing: true),
  ]);
  check(
    deliveredWin.finished && !deliveredWin.active,
    'A delivered winning move leaves the active match list',
  );
  final pause = invite.control('pause', 2);
  final resume = invite.control('resume', 3);
  final failedPause = replay([
    message(start, outgoing: true),
    message(pause, outgoing: true, state: 24),
  ]);
  check(
    failedPause.pending?.text == pause.wire,
    'A failed pause is available to retry',
  );
  final failedResume = replay([
    message(start, outgoing: true),
    message(pause, outgoing: true),
    message(resume, outgoing: true, state: 24),
  ]);
  check(
    failedResume.paused && failedResume.pending?.text == resume.wire,
    'A failed resume preserves the confirmed pause and can be retried',
  );
  final retriedResume = replay([
    message(start, outgoing: true),
    message(resume, outgoing: true),
    message(pause, outgoing: true),
    message(resume, outgoing: true, state: 24),
  ]);
  check(
    !retriedResume.paused && retriedResume.pending == null,
    'A delivered resume supersedes an older pause and its own failed retry',
  );
  print(
    'PASS: match readiness, start and quit delivery, retry, and legacy replay.',
  );

  final secondGame = GameLink.parse(
    'https://justtrysomthing.github.io/zompa/game/'
    '?id=sample-rules&build=1&sha=${'b' * 64}',
  )!;
  final generic = MatchEvent.invite(secondGame, turnProtocol: true);
  final initial = generic.control('resume', 1);
  final ready = [
    message(generic, outgoing: true),
    message(generic.accept(), outgoing: false),
    message(initial, outgoing: true),
  ];
  OnlineMatch genericReplay(List<FriendMessage> events) =>
      OnlineMatch.replay(generic.id, [...ready, ...events])!;
  final first = generic.turn('0' * 64, 'piece7_square3');
  final firstSent = message(first, outgoing: true);
  final genericPending = genericReplay([
    message(first, outgoing: true, state: 20),
  ]);
  check(
    genericPending.started &&
        !genericPending.myTurn &&
        genericPending.turnHistory.isEmpty &&
        genericPending.pending != null,
    'Generic play waits for a pending first turn',
  );
  final genericBoard = genericReplay([firstSent, firstSent]);
  check(
    genericBoard.turnHistory.single == 'piece7_square3' && !genericBoard.myTurn,
    'Generic replay uses game-specific tokens and deduplicates delivery',
  );
  final response = generic.turn(
    genericBoard.turnHead,
    'piece2_square4',
    outcome: 2,
  );
  final finished = genericReplay([
    message(response, outgoing: false),
    firstSent,
  ]);
  check(
    finished.finished &&
        finished.winner == 2 &&
        finished.turnHistory.length == 2,
    'Out-of-order delivery reconstructs the generic match and its result',
  );
  check(
    genericReplay([message(response, outgoing: true), firstSent])
            .turnHistory
            .length ==
        1,
    'A turn from the wrong player is ignored',
  );
  check(
    genericReplay([
      firstSent,
      message(generic.turn('0' * 64, 'different'), outgoing: true),
    ]).conflict,
    'Divergent turns stop a generic match',
  );
  print(
    'PASS: game-specific turn tokens, delivery, ordering, conflict, and result.',
  );
  const total = 4097;
  final long = MatchEvent.invite(secondGame, longTurns: true);
  check(
    MatchEvent.parse(long.wire)?.onlineProtocol == 'turns-v2',
    'Long protocol survives invitation parsing',
  );
  final history = <FriendMessage>[];
  var head = '0' * 64;
  for (var i = 0; i < total; i++) {
    final event = long.turn(
      head,
      i.toString().padLeft(256, 'x'),
      outcome: i == total - 1 ? 1 : null,
    );
    history.add(message(event, outgoing: i.isEven));
    head = sha256.convert(utf8.encode(event.wire)).toString();
  }
  OnlineMatch longReplay(int count, {bool mine = true}) =>
      OnlineMatch.replay(long.id, [
        message(long, outgoing: mine),
        message(long.accept(), outgoing: !mine),
        message(long.control('resume', 1), outgoing: mine),
        if (mine)
          ...history.take(count)
        else
          for (final event in history.take(count))
            message(MatchEvent.parse(event.text)!, outgoing: !event.outgoing),
      ])!;
  for (final count in [512, 513, 4096]) {
    final open = longReplay(count);
    check(
      open.turnHistory.length == count && !open.boardComplete,
      'The host must keep a turns-v2 match open at $count',
    );
    final pages = open.sdkTurnPages();
    check(
      pages.every((page) => page.length <= 32895) &&
          pages.join(',') == open.turnHistory.join(','),
      'A maximum-size history must be split without losing entries',
    );
    check(
      longReplay(count, mine: false).turnHead == open.turnHead,
      'Both players must reconstruct the same match after reopening',
    );
  }
  final longFinished = longReplay(total);
  check(
    longFinished.boardComplete &&
        longFinished.winner == 1 &&
        longFinished.turnHistory.length == total &&
        longFinished.turnHead == head,
    'The game can report its winner beyond 4096 entries',
  );
  print(
    'PASS: 4097 maximum-size entries, bounded pages, reconnect for both sides, and game-reported outcome.',
  );
}
