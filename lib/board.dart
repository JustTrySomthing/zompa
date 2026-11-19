import 'dart:math';

class Board {
  Board() : cells = List.filled(42, 0);
  Board.from(List<dynamic> data) : cells = data.cast<int>().toList();
  final List<int> cells;
  int get count => cells.where((piece) => piece != 0).length;
  int get turn => count.isEven ? 1 : 2;
  bool get full => !cells.contains(0);

  int landing(int column) {
    if (column < 0 || column >= 7) return -1;
    for (var row = 5; row >= 0; row--) {
      if (cells[row * 7 + column] == 0) return row * 7 + column;
    }
    return -1;
  }

  int get winner {
    const directions = [(0, 1), (1, 0), (1, 1), (1, -1)];
    for (var r = 0; r < 6; r++) {
      for (var c = 0; c < 7; c++) {
        final side = cells[r * 7 + c];
        if (side == 0) continue;
        for (final (dr, dc) in directions) {
          if (r + 3 * dr >= 6 || c + 3 * dc < 0 || c + 3 * dc >= 7) continue;
          if (List.generate(
            4,
            (i) => cells[(r + i * dr) * 7 + c + i * dc],
          ).every((piece) => piece == side)) {
            return side;
          }
        }
      }
    }
    return 0;
  }

  bool drop(int column) {
    final slot = landing(column);
    if (slot < 0 || winner != 0) return false;
    cells[slot] = turn;
    return true;
  }

  int computerMove() {
    const centerFirst = [3, 2, 4, 1, 5, 0, 6];
    final available = centerFirst
        .where((column) => landing(column) >= 0)
        .toList();
    if (available.isEmpty) return -1;
    final sideToPlay = turn;
    for (final side in [sideToPlay, 3 - sideToPlay]) {
      for (final column in available) {
        final slot = landing(column);
        cells[slot] = side;
        final wins = winner == side;
        cells[slot] = 0;
        if (wins) return column;
      }
    }
    return available[Random().nextInt(min(3, available.length))];
  }
}
