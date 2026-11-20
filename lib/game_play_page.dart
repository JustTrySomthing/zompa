import 'package:flutter/material.dart';

import 'game_audio.dart';
import 'github_distribution.dart';
import 'love_player.dart';

class GamePlayPage extends StatefulWidget {
  const GamePlayPage.official({
    super.key,
    required this.game,
    required this.title,
    required this.mode,
  }) : importedId = null;

  const GamePlayPage.imported({
    super.key,
    required this.importedId,
    required this.title,
  }) : game = null,
       mode = 'solo';

  final GameRelease? game;
  final String? importedId;
  final String title, mode;

  @override
  State<GamePlayPage> createState() => _GamePlayPageState();
}

class _GamePlayPageState extends State<GamePlayPage> {
  bool _paused = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      actions: [
        const GameAudioButton(),
        IconButton(
          tooltip: 'Pause game',
          onPressed: _paused ? null : () => setState(() => _paused = true),
          icon: const Icon(Icons.pause),
        ),
      ],
    ),
    body: SafeArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            ignoring: _paused,
            child: widget.game != null
                ? LoveGameView.official(
                    game: widget.game!,
                    mode: widget.mode,
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
                        onPressed: () => setState(() => _paused = false),
                        child: const Text('Resume'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
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
  );
}
