import 'package:flutter/material.dart';

class GameAudio extends ChangeNotifier {
  GameAudio(Map<String, dynamic> data, this._write)
    : _lowerDuringCalls = data['lowerGameAudioDuringCalls'] != false,
      _muted = data['gameAudioMuted'] == true,
      _levels = [
        _read(data, 'gameVolume'),
        _read(data, 'gameMusic'),
        _read(data, 'gameEffects', fallback: data['effects'] == false ? 0 : 1),
      ];

  static const _keys = ['gameVolume', 'gameMusic', 'gameEffects'];
  final void Function(String, dynamic) _write;
  final List<double> _levels;
  bool _lowerDuringCalls;
  bool _muted;

  static double _read(
    Map<String, dynamic> data,
    String key, {
    double fallback = 1,
  }) {
    final value = data[key];
    return value is num && value.isFinite
        ? value.clamp(0, 1).toDouble()
        : fallback;
  }

  double level(int index) => _levels[index];

  bool get lowerDuringCalls => _lowerDuringCalls;
  bool get muted => _muted;

  String playerSettings({required bool callAudioActive}) {
    final master = _muted ? 0.0 : _levels[0];
    final gain = callAudioActive && _lowerDuringCalls ? 0.25 : 1.0;
    return [
      master * gain,
      _levels[1],
      _levels[2],
    ].map((level) => (level * 100).round()).join(':');
  }

  void setLowerDuringCalls(bool value) {
    if (_lowerDuringCalls == value) return;
    _lowerDuringCalls = value;
    _write('lowerGameAudioDuringCalls', value);
    notifyListeners();
  }

  void setMuted(bool value) {
    if (_muted == value) return;
    _muted = value;
    _write('gameAudioMuted', value);
    notifyListeners();
  }

  void setLevel(int index, double level) {
    if (_levels[index] == level) return;
    _levels[index] = level;
    _write(_keys[index], level);
    notifyListeners();
  }
}

class GameAudioScope extends InheritedNotifier<GameAudio> {
  const GameAudioScope({
    super.key,
    required GameAudio audio,
    required super.child,
  }) : super(notifier: audio);

  static GameAudio? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GameAudioScope>()?.notifier;
}

class GameAudioButton extends StatelessWidget {
  const GameAudioButton({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => const SafeArea(child: _GameAudioControls()),
    );
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Game audio',
    onPressed: () => show(context),
    icon: const Icon(Icons.volume_up_outlined),
  );
}

class _GameAudioControls extends StatelessWidget {
  const _GameAudioControls();

  @override
  Widget build(BuildContext context) {
    final audio = GameAudioScope.of(context);
    if (audio == null) return const SizedBox.shrink();
    const labels = ['Game volume', 'Music', 'Sound effects'];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Game audio', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mute game audio'),
            value: audio.muted,
            onChanged: audio.setMuted,
          ),
          for (var index = 0; index < labels.length; index++) ...[
            Text('${labels[index]} · ${(audio.level(index) * 100).round()}%'),
            Slider(
              value: audio.level(index),
              divisions: 20,
              semanticFormatterCallback: (level) =>
                  '${labels[index]} ${(level * 100).round()}%',
              onChanged: (level) => audio.setLevel(index, level),
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Lower game audio during calls'),
            value: audio.lowerDuringCalls,
            onChanged: audio.setLowerDuringCalls,
          ),
          const Text(
            'Music and sound effects are separate in games that use the Zompado SDK.',
          ),
        ],
      ),
    );
  }
}
