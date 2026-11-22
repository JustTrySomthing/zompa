import 'package:flutter/material.dart';

class GameAudio extends ChangeNotifier {
  GameAudio(Map<String, dynamic> data, this._write)
    : _lowerDuringCalls = data['lowerGameAudioDuringCalls'] != false,
      _mutes = [
        data['gameAudioMuted'] == true,
        data['gameMusicMuted'] == true,
        data['gameEffectsMuted'] == true,
      ],
      _levels = [
        _read(data, 'gameVolume', fallback: 0.2),
        _read(data, 'gameMusic'),
        _read(data, 'gameEffects', fallback: data['effects'] == false ? 0 : 1),
      ];

  static const _keys = ['gameVolume', 'gameMusic', 'gameEffects'];
  static const _muteKeys = [
    'gameAudioMuted',
    'gameMusicMuted',
    'gameEffectsMuted',
  ];
  final void Function(String, dynamic) _write;
  final List<double> _levels;
  bool _lowerDuringCalls;
  final List<bool> _mutes;

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
  bool muted(int index) => _mutes[index];

  String playerSettings({required bool callAudioActive}) {
    final gain = callAudioActive && _lowerDuringCalls ? 0.25 : 1.0;
    return [
      for (var i = 0; i < _levels.length; i++)
        muted(i) ? 0.0 : _levels[i] * (i == 0 ? gain : 1.0),
    ].map((level) => (level * 100).round()).join(':');
  }

  void setLowerDuringCalls(bool value) {
    if (_lowerDuringCalls == value) return;
    _lowerDuringCalls = value;
    _write('lowerGameAudioDuringCalls', value);
    notifyListeners();
  }

  void toggleMute(int index) {
    _mutes[index] = !_mutes[index];
    _write(_muteKeys[index], _mutes[index]);
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
      useSafeArea: true,
      builder: (context) => const SafeArea(child: _GameAudioControls()),
    );
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Game audio',
    onPressed: () => show(context),
    isSelected: GameAudioScope.of(context)?.muted(0) ?? false,
    icon: const Icon(Icons.volume_up_outlined),
    selectedIcon: const Icon(Icons.volume_off_outlined),
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
          Row(
            children: [
              Expanded(
                child: Text(
                  'Game audio',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton.outlined(
                tooltip: audio.muted(0)
                    ? 'Unmute game volume'
                    : 'Mute game volume',
                style: IconButton.styleFrom(shape: const CircleBorder()),
                isSelected: audio.muted(0),
                icon: const Icon(Icons.volume_up_outlined),
                selectedIcon: const Icon(Icons.volume_off_outlined),
                onPressed: () => audio.toggleMute(0),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < labels.length; index++) ...[
            Text('${labels[index]} · ${(audio.level(index) * 100).round()}%'),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: audio.level(index),
                    divisions: 20,
                    semanticFormatterCallback: (level) =>
                        '${labels[index]} ${(level * 100).round()}%',
                    onChanged: (level) => audio.setLevel(index, level),
                  ),
                ),
                if (index > 0)
                  IconButton(
                    tooltip:
                        '${audio.muted(index) ? 'Unmute' : 'Mute'} ${labels[index].toLowerCase()}',
                    isSelected: audio.muted(index),
                    icon: const Icon(Icons.volume_up_outlined),
                    selectedIcon: const Icon(Icons.volume_off_outlined),
                    onPressed: () => audio.toggleMute(index),
                  ),
              ],
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Lower game audio during calls'),
            value: audio.lowerDuringCalls,
            onChanged: audio.setLowerDuringCalls,
          ),
          const Text(
            'Music and sound effects are separate in games that use the Zompa SDK.',
          ),
        ],
      ),
    );
  }
}
