import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_chrome.dart';

const _host = MethodChannel('io.zompado.host');

void recordAppEvent(String event) {
  unawaited(
    _host
        .invokeMethod<void>('recordAppEvent', {'event': event})
        .onError<MissingPluginException>((_, _) {})
        .onError<PlatformException>((_, _) {}),
  );
}

class AppLogPage extends StatefulWidget {
  const AppLogPage({super.key});

  @override
  State<AppLogPage> createState() => _AppLogPageState();
}

class _AppLogPageState extends State<AppLogPage> with WidgetsBindingObserver {
  String? _log, _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh({bool clear = false, bool copy = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (clear) await _host.invokeMethod<void>('clearAppLog');
      final log = await _host.invokeMethod<String>('readAppLog');
      if (copy && log != null) {
        await Clipboard.setData(ClipboardData(text: log));
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('App log copied.')));
        }
      }
      if (mounted) setState(() => _log = log);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load App Log.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: chatPageBar(
      context,
      'App Log',
      firstActions: [
        IconButton(
          tooltip: 'Refresh log',
          icon: const Icon(Icons.refresh),
          onPressed: _busy ? null : _refresh,
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error case final error?)
            Padding(padding: const EdgeInsets.all(16), child: Text(error)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                _log ?? '',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy || _log == null
                      ? null
                      : () => _refresh(copy: true),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy Log'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy || _log == null
                      ? null
                      : () => _refresh(clear: true),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear Log'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
