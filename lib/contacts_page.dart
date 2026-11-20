import 'package:flutter/material.dart';

import 'chatmail.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.chatmail,
    required this.invite,
    required this.acceptInvite,
    required this.open,
  });

  final Chatmail chatmail;
  final Future<void> Function() invite, acceptInvite;
  final Future<void> Function(ChatContact) open;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  List<ChatContact> _contacts = [];
  List<ChatContact> _blocked = [];
  String _query = '';
  String? _error;
  bool _loading = true;
  bool _showBlocked = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lists = await Future.wait([
        widget.chatmail.contacts(),
        widget.chatmail.contacts(blocked: true),
      ]);
      if (!mounted) return;
      setState(() {
        _contacts = lists[0];
        _blocked = lists[1];
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load contacts.');
    } finally {
      if (mounted) setState(() => _loading = false);
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
    final visible = (_showBlocked ? _blocked : _contacts).where(
      (contact) =>
          '${contact.name} ${contact.address}'.toLowerCase().contains(_query),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
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
                FilledButton.icon(
                  icon: const Icon(Icons.person_add_outlined),
                  onPressed: () async {
                    await widget.invite();
                    if (mounted) await _load();
                  },
                  label: const Text('Add contact'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    await widget.acceptInvite();
                    if (mounted) await _load();
                  },
                  child: const Text('Accept invite'),
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
            if (_error case final error?)
              ListTile(title: Text(error), onTap: _load),
            if (!_loading && _error == null && visible.isEmpty)
              Text(
                _query.isNotEmpty
                    ? 'No matching contacts.'
                    : _showBlocked
                    ? 'No blocked contacts.'
                    : 'No contacts yet.',
              ),
            for (final contact in visible)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(contact.name),
                subtitle: contact.address.isEmpty
                    ? null
                    : Text(
                        contact.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: _showBlocked ? null : () => _open(contact),
                trailing: PopupMenuButton<String>(
                  tooltip: 'Manage contact',
                  onSelected: (value) => _manage(contact, value),
                  itemBuilder: (_) => [
                    if (_showBlocked)
                      const PopupMenuItem(
                        value: 'unblock',
                        child: Text('Unblock'),
                      )
                    else ...[
                      const PopupMenuItem(value: 'block', child: Text('Block')),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
