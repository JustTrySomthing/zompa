import '../lib/chatmail.dart';
import '../lib/game_link.dart';
import '../lib/online_match.dart';

void main() {
  final game = GameLink.parse(
    'https://justtrysomthing.github.io/zompado/game/'
    '?id=drop-four&build=5&sha=${'a' * 64}',
  )!;
  final invite = MatchEvent.invite(game);
  final start = invite.control('resume', 1);

  FriendMessage message(
    MatchEvent event, {
    required bool outgoing,
    int? state,
  }) => FriendMessage.fromJson({
    'id': 1,
    'state': state ?? (outgoing ? 26 : 10),
    'text': event.wire,
    'fromId': outgoing ? 1 : 2,
    'showPadlock': true,
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
    unanswered.active && !unanswered.accepted && unanswered.pending?.state == 24,
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
}
