import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_chrome.dart';
import 'chat_files.dart';
import 'chatmail.dart';

const _host = MethodChannel('io.zompado.host');

class QuietHoursPage extends StatefulWidget {
  const QuietHoursPage({super.key});

  @override
  State<QuietHoursPage> createState() => _QuietHoursPageState();
}

class _QuietHoursPageState extends State<QuietHoursPage> {
  bool _enabled = false;
  int _start = 22 * 60;
  int _end = 8 * 60;
  int _days = 127;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await _host.invokeMapMethod<String, Object>(
        'quietHours',
      );
      if (settings == null || !mounted) return;
      setState(() {
        _enabled = settings['enabled'] == true;
        _start = settings['start'] as int;
        _end = settings['end'] as int;
        _days = settings['days'] as int;
        _loading = false;
      });
    } on PlatformException {
      if (mounted) setState(() => _error = 'Couldn’t read Quiet Hours.');
    }
  }

  TimeOfDay _time(int value) =>
      TimeOfDay(hour: value ~/ 60, minute: value % 60);

  Future<void> _pick(bool start) async {
    final chosen = await showTimePicker(
      context: context,
      initialTime: _time(start ? _start : _end),
    );
    if (chosen == null || !mounted) return;
    final minutes = chosen.hour * 60 + chosen.minute;
    setState(() {
      if (start) {
        _start = minutes;
      } else {
        _end = minutes;
      }
    });
  }

  Future<void> _save() async {
    try {
      final saved = await _host.invokeMethod<bool>('setQuietHours', {
        'enabled': _enabled,
        'start': _start,
        'end': _end,
        'days': _days,
      });
      if (saved == true && mounted) {
        Navigator.of(context).pop();
        return;
      }
    } on PlatformException {
      // Keep the schedule visible if Android could not save it.
    }
    if (mounted) setState(() => _error = 'Couldn’t save Quiet Hours.');
  }

  @override
  Widget build(BuildContext context) {
    final validation = !_enabled
        ? null
        : _days == 0
        ? 'Choose at least one day.'
        : _start == _end
        ? 'Choose different start and end times.'
        : null;
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quiet Hours'),
        actions: chatActions(context),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable schedule'),
              subtitle: const Text(
                'Calls and notifications arrive silently during Quiet Hours.',
              ),
              value: _enabled,
              onChanged: _loading
                  ? null
                  : (value) => setState(() => _enabled = value),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton(
                  onPressed: _enabled ? () => _pick(true) : null,
                  child: Text('From ${_time(_start).format(context)}'),
                ),
                OutlinedButton(
                  onPressed: _enabled ? () => _pick(false) : null,
                  child: Text('Until ${_time(_end).format(context)}'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Repeat'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (var d = 0; d < 7; d++)
                  FilterChip(
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    label: Text(labels[d]),
                    tooltip: const [
                      'Monday',
                      'Tuesday',
                      'Wednesday',
                      'Thursday',
                      'Friday',
                      'Saturday',
                      'Sunday',
                    ][d],
                    selected: (_days & (1 << d)) != 0,
                    onSelected: _enabled
                        ? (_) => setState(() => _days ^= 1 << d)
                        : null,
                  ),
              ],
            ),
            if (validation ?? _error case final feedback?) Text(feedback),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loading || validation != null ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.chatmail});

  final Chatmail chatmail;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  late final _existing = widget.chatmail.restore();
  bool _busy = false;
  bool _restored = false;
  String? _status;

  Future<void> _backup(bool export) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    Directory? staging;
    ChatFile? selected;
    try {
      if (!export) {
        selected = await ChatFile.pick('*/*');
        if (selected == null || !mounted) return;
      }
      final password = await showDialog<String>(
        context: context,
        builder: (_) => _BackupPassword(create: export),
      );
      if (password == null || !mounted) return;
      final cache = await _host.invokeMethod<String>('backupCache');
      if (cache == null) throw const FileSystemException('No backup storage');
      staging = await Directory(cache).createTemp('zompado-backup-');
      if (export) {
        await widget.chatmail.exportBackup(staging.path);
        final archive = await staging.list().firstWhere(
          (file) => file.path.endsWith('.tar'),
        );
        final encrypted = '${staging.path}/archive.zompbackup';
        await _cipher(archive.path, encrypted, password, true);
        await archive.delete();
        if (!mounted) return;
        if (await _host.invokeMethod<bool>('saveBackup', encrypted) == true &&
            mounted) {
          setState(() => _status = 'Backup saved.');
        }
      } else {
        final archive = '${staging.path}/restore.tar';
        await _cipher(selected!.path, archive, password, false);
        await widget.chatmail.importBackup(archive);
        if (mounted)
          setState(() {
            _restored = true;
            _status = 'Chat profile and messages restored.';
          });
      }
    } on PlatformException catch (error) {
      if (mounted)
        setState(() => _status = error.message ?? 'Couldn’t open the backup.');
    } catch (_) {
      if (mounted)
        setState(
          () => _status = export
              ? 'Couldn’t create the backup.'
              : 'Couldn’t restore this backup.',
        );
    } finally {
      if (staging != null) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          // Temporary backup storage is private to the app.
        }
      }
      await selected?.discard();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cipher(
    String source,
    String destination,
    String password,
    bool encrypt,
  ) => _host.invokeMethod<void>('backupCipher', {
    'source': source,
    'destination': destination,
    'password': password,
    'encrypt': encrypt,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Backup'), actions: chatActions(context)),
    body: SafeArea(
      child: FutureBuilder<bool>(
        future: _existing,
        builder: (context, snapshot) {
          final hasProfile = snapshot.data == true || _restored;
          final available = snapshot.hasData;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Save your Chatmail profile, contacts, conversations, and attachments in a password-protected file.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.save_outlined),
                onPressed: !_busy && available && hasProfile
                    ? () => _backup(true)
                    : null,
                label: const Text('Create backup'),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.restore),
                onPressed: !_busy && available && !hasProfile
                    ? () => _backup(false)
                    : null,
                label: const Text('Restore backup'),
              ),
              const SizedBox(height: 12),
              Text(
                hasProfile
                    ? 'To restore, open Backup on your new phone before creating a chat profile.'
                    : 'Keep the backup file and password together when moving to a new phone.',
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_status case final status?) Text(status),
              if (snapshot.hasError)
                const Text('Couldn’t check your chat profile.'),
            ],
          );
        },
      ),
    ),
  );
}

class _BackupPassword extends StatefulWidget {
  const _BackupPassword({required this.create});

  final bool create;

  @override
  State<_BackupPassword> createState() => _BackupPasswordState();
}

class _BackupPasswordState extends State<_BackupPassword> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.create ? 'Create encrypted backup' : 'Restore backup'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          autofocus: true,
          obscureText: true,
          controller: _password,
          decoration: const InputDecoration(labelText: 'Backup password'),
        ),
        if (widget.create)
          TextField(
            obscureText: true,
            controller: _repeat,
            decoration: const InputDecoration(labelText: 'Confirm password'),
          ),
        if (_error case final error?) Text(error),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final password = _password.text;
          if (password.length < 12 || password.length > 1024) {
            setState(
              () => _error = 'Use at least 12 characters for the password.',
            );
          } else if (widget.create && password != _repeat.text) {
            setState(() => _error = 'The passwords don’t match.');
          } else {
            Navigator.pop(context, password);
          }
        },
        child: Text(widget.create ? 'Continue' : 'Restore'),
      ),
    ],
  );
}

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key, required this.chatmail});

  final Chatmail chatmail;

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  late Future<List<(String, String)>> _details = _load();

  Future<List<(String, String)>> _load() async {
    final relay = await widget.chatmail.connectionInfo();
    final call = await _host.invokeMapMethod<String, String>(
      'lastCallConnection',
    );
    final ips = <String>{};
    if (relay != null && relay.server.isNotEmpty) {
      try {
        ips.addAll(
          (await InternetAddress.lookup(relay.server)
                  .timeout(const Duration(seconds: 6)))
              .map((ip) => ip.address),
        );
      } catch (_) {
        // Connection details can still be shown when DNS is unavailable.
      }
    }
    return [
      (
        'Chatmail',
        switch (relay?.status) {
          4000 => 'Connected',
          3000 => 'Checking for messages',
          2000 => 'Connecting',
          null => 'No profile',
          _ => 'Disconnected',
        },
      ),
      if (relay != null) ...[
        ('Profile address', relay.address),
        ('Chatmail server', relay.server),
        (
          'Server IP addresses (DNS)',
          ips.isEmpty ? 'Unavailable' : ips.join('\n'),
        ),
        ('Messaging transport', 'TCP (IMAP and SMTP)'),
      ],
      ('Last call transport', call?['protocol'] ?? 'Unavailable'),
      if (call?['relay'] case final ip?) ('Last call relay IP', ip),
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Connections'),
      actions: chatActions(context),
    ),
    body: SafeArea(
      child: FutureBuilder<List<(String, String)>>(
        future: _details,
        builder: (context, snapshot) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (snapshot.connectionState != ConnectionState.done)
              const LinearProgressIndicator(),
            if (snapshot.hasError)
              const Text('Couldn’t load connection details.'),
            for (final (label, value)
                in snapshot.data ?? const <(String, String)>[])
              ListTile(
                title: Text(label),
                subtitle: SelectableText(value),
                trailing: label == 'Profile address'
                    ? IconButton(
                        tooltip: 'Copy address',
                        icon: const Icon(Icons.copy_outlined),
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: value)),
                      )
                    : null,
              ),
            TextButton(
              onPressed: () => setState(() => _details = _load()),
              child: const Text('Refresh'),
            ),
          ],
        ),
      ),
    ),
  );
}
