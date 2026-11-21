import 'dart:async';

import 'package:flutter/material.dart';

import 'chatmail.dart';
import 'chat_avatar.dart';
import 'chat_chrome.dart';
import 'dialog_actions.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.chatmail,
    required this.invite,
    required this.acceptInvite,
    required this.open,
    required this.pins,
    required this.savePins,
  });

  final Chatmail chatmail;
  final Future<void> Function() invite, acceptInvite;
  final Future<void> Function(ChatContact) open;
  final Set<int> pins;
  final ValueChanged<Set<int>> savePins;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  List<ChatContact> _contacts = [];
  List<ChatContact> _blocked = [];
  String _query = '';
  String? _loadError, _error;
  bool _loading = true;
  int _request = 0;
  StreamSubscription<void>? _changes;
  Timer? _refresh;
  bool _showBlocked = false;
  late final _pins = {...widget.pins};

  @override
  void initState() {
    super.initState();
    _changes = widget.chatmail.changes.listen((_) {
      _refresh?.cancel();
      _refresh = Timer(
        const Duration(milliseconds: 300),
        () => _load(quiet: true),
      );
    });
    _load();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!mounted || (quiet && _loading)) return;
    final request = ++_request;
    if (!quiet)
      setState(() {
        _loading = true;
        _loadError = null;
        _error = null;
      });
    try {
      final lists = await Future.wait([
        widget.chatmail.contacts(),
        widget.chatmail.contacts(blocked: true),
      ]);
      if (!mounted || request != _request) return;
      setState(() {
        _loadError = null;
        _error = null;
        _contacts = lists[0];
        _blocked = lists[1];
      });
    } catch (_) {
      if (mounted && request == _request && !quiet)
        setState(() => _loadError = 'Couldn’t load contacts.');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _manage(ChatContact contact, String action) async {
    if (action == 'delete' || action == 'block') {
      final deleting = action == 'delete';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('${deleting ? 'Delete' : 'Block'} ${contact.name}?'),
          content: Text(
            deleting
                ? 'Remove this contact from your contacts.'
                : 'Stop messages and calls from this contact.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: deleting ? destructiveDialogAction(dialog) : null,
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(deleting ? 'Delete contact' : 'Block contact'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    try {
      await widget.chatmail.manageContact(contact.id, action);
      if (action == 'delete' && _pins.remove(contact.id))
        widget.savePins(_pins);
      if (mounted) await _load();
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t update this contact.');
    }
  }

  Future<void> _open(ChatContact contact) async {
    try {
      await widget.open(contact);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t open this conversation.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final matching = (_showBlocked ? _blocked : _contacts)
        .where((contact) => contact.name.toLowerCase().contains(_query))
        .toList();
    final visible = [
      ...matching.where(
        (contact) => !_showBlocked && _pins.contains(contact.id),
      ),
      ...matching.where(
        (contact) => _showBlocked || !_pins.contains(contact.id),
      ),
    ];
    return Scaffold(
      appBar: chatPageBar(
        context,
        'Contacts',
        selected: ChatDestination.contacts,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              decoration: const InputDecoration(
                labelText: 'Find a contact',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () async {
                    await widget.invite();
                    if (mounted) await _load();
                  },
                  child: const Text('Share my invite'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    await widget.acceptInvite();
                    if (mounted) await _load();
                  },
                  child: const Text('Accept an invite'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show blocked contacts'),
              value: _showBlocked,
              onChanged: (value) => setState(() => _showBlocked = value),
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_loadError case final error?)
              ListTile(
                title: Text(error),
                trailing: TextButton(
                  onPressed: _loading ? null : () => _load(),
                  child: const Text('Retry'),
                ),
              ),
            if (_error case final error?) ListTile(title: Text(error)),
            if (!_loading &&
                _loadError == null &&
                _error == null &&
                visible.isEmpty)
              Text(
                _query.isNotEmpty
                    ? 'No matching contacts.'
                    : _showBlocked
                    ? 'No blocked contacts.'
                    : 'No contacts yet.',
              ),
            for (final contact in visible)
              ListTile(
                leading: ChatAvatar(contact.name, photo: contact.photo),
                title: Text(contact.name),
                onTap: _showBlocked ? null : () => _open(contact),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_showBlocked)
                      IconButton(
                        tooltip: _pins.contains(contact.id)
                            ? 'Unpin contact'
                            : 'Pin contact',
                        icon: Icon(
                          _pins.contains(contact.id)
                              ? Icons.push_pin
                              : Icons.push_pin_outlined,
                          color: _pins.contains(contact.id)
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        onPressed: () {
                          setState(() {
                            if (!_pins.add(contact.id))
                              _pins.remove(contact.id);
                          });
                          widget.savePins(_pins);
                        },
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'Manage contact',
                      onSelected: (value) => _manage(contact, value),
                      itemBuilder: (_) => [
                        if (_showBlocked)
                          const PopupMenuItem(
                            value: 'unblock',
                            child: Text('Unblock'),
                          )
                        else ...[
                          const PopupMenuItem(
                            value: 'block',
                            child: Text('Block'),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
