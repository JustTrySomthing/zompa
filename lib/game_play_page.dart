import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'game_toolbar.dart';
import 'github_distribution.dart';
import 'love_player.dart';

class GamePlayPage extends StatefulWidget {
  const GamePlayPage.official({
    super.key,
    required this.game,
    required this.title,
    required this.mode,
    this.fresh = true,
  }) : importedId = null;

  const GamePlayPage.imported({
    super.key,
    required this.importedId,
    required this.title,
  }) : game = null,
       mode = 'solo',
       fresh = true;

  final GameRelease? game;
  final String? importedId;
  final String title, mode;
  final bool fresh;

  @override
  State<GamePlayPage> createState() => _GamePlayPageState();
}

class _GamePlayPageState extends State<GamePlayPage> {
  var _player = GlobalKey<LoveGameViewState>();
  late bool _fresh = widget.fresh;
  bool _paused = false;
  bool _leaving = false;
  bool _reading = false;

  bool get _isCatsVsDogs => widget.game?.id == 'drop-four';

  bool get _hasLocalSaves => widget.game?.supportsLocalSaves ?? false;

  Future<void> _leave({required bool quit, required bool wasPaused}) async {
    if (_leaving) return;
    setState(() {
      _leaving = true;
      _paused = true;
    });
    try {
      if (_hasLocalSaves) await _player.currentState?.leave(quit: quit);
      if (mounted) Navigator.of(context).pop();
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _leaving = false;
        _paused = wasPaused;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            quit
                ? 'Couldn’t quit the game. Try again.'
                : 'Couldn’t save the game. Try again.',
          ),
        ),
      );
    }
  }

  Future<void> _newGame() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: const Text('Start a new game?'),
          content: const Text('This will replace your current match progress.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Start new game'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      // Finish the old player's save before reopening the same mode fresh.
      // Fresh launch clears only that slot, after the new runtime loads it.
      await _player.currentState?.leave(quit: false);
      if (!mounted) return;
      setState(() {
        _player = GlobalKey<LoveGameViewState>();
        _fresh = true;
        _paused = false;
      });
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t start a new game. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  Future<void> _quit() async {
    if (_leaving) return;
    final wasPaused = _paused;
    setState(() => _paused = true);
    final quit = _isCatsVsDogs
        ? await confirmQuitMatch(
            context,
            message: 'This will discard your progress in this match.',
          )
        : await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
              scrollable: true,
              title: const Text('Quit this game?'),
              content: _hasLocalSaves
                  ? const Text('This will discard your progress in this game.')
                  : null,
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('Keep playing'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Quit game'),
                ),
              ],
            ),
          );
    if (!mounted) return;
    if (quit == true) {
      await _leave(quit: true, wasPaused: wasPaused);
    } else {
      setState(() => _paused = wasPaused);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_hasLocalSaves,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _hasLocalSaves) _leave(quit: false, wasPaused: _paused);
    },
    child: AbsorbPointer(
      absorbing: _leaving,
      child: Scaffold(
        appBar: GameToolbar(
          title: widget.title,
          onHelp: () async {
            if (_reading || _leaving) return;
            setState(() => _reading = true);
            try {
              await showGameInstructions(
                context,
                _player.currentState?.instructions(),
                fourInARow: _isCatsVsDogs,
              );
            } finally {
              if (mounted) setState(() => _reading = false);
            }
          },
          hasAdvancedSettings: () async =>
              await _player.currentState?.hasAdvancedSettings() ?? false,
          onAdvancedSettings: () => _player.currentState?.openAdvancedSettings(),
          paused: _paused,
          onPause: _leaving ? null : () => setState(() => _paused = !_paused),
        ),
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                ignoring: _paused,
                child: widget.game != null
                    ? LoveGameView.official(
                        key: _player,
                        fresh: _fresh,
                        game: widget.game!,
                        mode: widget.mode,
                        paused: _paused || _reading,
                      )
                    : LoveGameView.imported(
                        key: _player,
                        id: widget.importedId!,
                        paused: _paused || _reading,
                      ),
              ),
              if (_paused)
                GamePausePanel(
                  onResume: _leaving
                      ? null
                      : () => setState(() => _paused = false),
                  onNewGame: _hasLocalSaves && !_leaving ? _newGame : null,
                  onQuit: _leaving ? null : _quit,
                  quitLabel: _isCatsVsDogs ? 'Quit match' : 'Quit game',
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
