import 'package:flutter/material.dart';

import 'chat_chrome.dart';
import 'chatmail.dart';

class CompressionPage extends StatefulWidget {
  const CompressionPage({super.key, required this.chatmail});
  final Chatmail chatmail;

  @override
  State<CompressionPage> createState() => _CompressionPageState();
}

class _CompressionPageState extends State<CompressionPage> {
  bool? _saver;
  bool _busy = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (!await widget.chatmail.restore()) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final saver = await widget.chatmail.dataSaver();
      if (mounted)
        setState(() {
          _saver = saver;
          _busy = false;
          _failed = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _busy = false;
          _failed = true;
        });
    }
  }

  Future<void> _choose(bool saver) async {
    if (_busy || _saver == saver) return;
    setState(() => _busy = true);
    try {
      await widget.chatmail.setDataSaver(saver);
      if (mounted) setState(() => _saver = saver);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t save this setting.')),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Compression'),
      actions: chatActions(context),
    ),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_failed)
          TextButton(
            onPressed: _load,
            child: const Text('Couldn’t load compression settings. Retry'),
          )
        else if (_saver == null && !_busy)
          const ListTile(
            title: Text('Create a chat profile to choose media quality.'),
          )
        else ...[
          for (final (quality, title, hint) in [
            (false, 'Balanced', 'Keep more detail while reducing media size.'),
            (true, 'Data saver', 'Use stronger compression to save data.'),
          ])
            ListTile(
              leading: Icon(
                _saver == quality
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(title),
              subtitle: Text(hint),
              selected: _saver == quality,
              enabled: !_busy && _saver != null,
              onTap: () => _choose(quality),
            ),
          const ListTile(
            leading: Icon(Icons.attach_file),
            title: Text('Original quality'),
            subtitle: Text(
              'Use Attach Original File when a photo, recording, or video needs to keep its original quality.',
            ),
          ),
        ],
      ],
    ),
  );
}
