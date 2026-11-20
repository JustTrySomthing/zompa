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
  print('PASS: match readiness, start delivery, retry, and legacy replay.');
}
