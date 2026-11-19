import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'love_player.dart';

class LoveImports extends StatefulWidget {
  const LoveImports({
    super.key,
    required this.host,
    required this.read,
    required this.save,
  });

  final MethodChannel host;
  final List<Object?> Function() read;
  final ValueChanged<List<Object?>> save;

  @override
  State<LoveImports> createState() => _LoveImportsState();
}

class _LoveImportsState extends State<LoveImports> {
  bool _busy = false;
  String? _error;

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.host.invokeMapMethod<String, Object?>(
        'importLoveGame',
      );
      if (result == null || !mounted) return;
      widget.save([
        result,
        for (final entry in widget.read())
          if (entry is Map && entry['id'] != result['id']) entry,
      ]);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? 'Import failed.');
    } on MissingPluginException {
      if (mounted) setState(() => _error = 'Game imports require Android.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String id) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final removed = await widget.host.invokeMethod<bool>('removeLoveGame', {
        'id': id,
      });
      if (!mounted) return;
      if (removed != true) {
        setState(() => _error = 'Couldn’t remove this file.');
        return;
      }
      widget.save([
        for (final entry in widget.read())
          if (entry is Map && entry['id'] != id) entry,
      ]);
    } on PlatformException {
      if (mounted) setState(() => _error = 'Couldn’t remove this file.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Import a .love game')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Choose a .love file to add a game from this device.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Choose .love file'),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            for (final entry in widget.read())
              if (entry case {
                'id': final String id,
                'title': final String title,
                'bytes': final int bytes,
              })
                Card(
                  child: ListTile(
                    title: Text(title),
                    subtitle: Text(
                      bytes < 1024
                          ? '$bytes B · .love'
                          : '${(bytes / 1024).toStringAsFixed(1)} KB · .love',
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        IconButton(
                          tooltip: 'Play',
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (_) => Scaffold(
                                      appBar: AppBar(title: Text(title)),
                                      body: SafeArea(
                                        child: LoveGameView.imported(id: id),
                                      ),
                                    ),
                                  ),
                                ),
                          icon: const Icon(Icons.play_arrow),
                        ),
                        IconButton(
                          tooltip: 'Remove saved copy',
                          onPressed: _busy ? null : () => _remove(id),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    ),
  );
}
