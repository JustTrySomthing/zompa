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
    required this.fresh,
  }) : importedId = null;

  const GamePlayPage.imported({
    super.key,
    required this.importedId,
    required this.title,
  }) : game = null,
       mode = 'solo',
       fresh = false;

  final GameRelease? game;
  final String? importedId;
  final String title, mode;
  final bool fresh;

  @override
  State<GamePlayPage> createState() => _GamePlayPageState();
}

class _GamePlayPageState extends State<GamePlayPage> {
  final _player = GlobalKey<LoveGameViewState>();
  bool _paused = false;
  bool _leaving = false;

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

  Future<void> _quit() async {
    if (_leaving) return;
    final wasPaused = _paused;
    setState(() => _paused = true);
    final quit = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
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
    child: Scaffold(
      appBar: GameToolbar(
        title: widget.title,
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
                      game: widget.game!,
                      mode: widget.mode,
                      fresh: widget.fresh,
                      paused: _paused,
                    )
                  : LoveGameView.imported(
                      id: widget.importedId!,
                      paused: _paused,
                    ),
            ),
            if (_paused) ...[
              const ModalBarrier(dismissible: false, color: Colors.black54),
              Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Game paused'),
                        const SizedBox(height: 10),
                        FilledButton(
                          onPressed: _leaving
                              ? null
                              : () => setState(() => _paused = false),
                          child: const Text('Resume'),
                        ),
                        TextButton(
                          onPressed: _leaving ? null : _quit,
                          child: const Text('Quit game'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
