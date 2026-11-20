import 'dart:io';

import 'package:flutter/material.dart';

import 'chat_files.dart';
import 'chatmail.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.chatmail});

  final Chatmail chatmail;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _name = TextEditingController();
  final _bio = TextEditingController();
  ChatFile? _draft;
  String? _photo;
  String? _error;
  bool _remove = false;
  bool _ready = false;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (!await widget.chatmail.restore()) {
        if (mounted)
          setState(() => _error = 'Create your chat profile in Chats first.');
        return;
      }
      final profile = await widget.chatmail.profile();
      if (!mounted) return;
      setState(() {
        _name.text = profile.name;
        _bio.text = profile.bio;
        _photo = profile.photo;
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load your profile.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    setState(() => _busy = true);
    try {
      final file = await ChatFile.pick('image/*');
      if (file == null) return;
      if (!mounted) {
        await file.discard();
        return;
      }
      await _draft?.discard();
      if (mounted) {
        setState(() {
          _draft = file;
          _remove = false;
          _error = null;
        });
      } else {
        await file.discard();
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t open that photo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a display name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.chatmail.editProfile(
        name,
        _bio.text.trim(),
        avatar: _remove ? '' : _draft?.path,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Couldn’t save your profile. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _draft?.discard();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = _remove ? null : _draft?.path ?? _photo;
    return Scaffold(
      appBar: AppBar(title: const Text('My profile')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?) Text(error),
            if (_ready) ...[
              Center(
                child: CircleAvatar(
                  radius: 44,
                  child: ClipOval(
                    child: photo == null
                        ? const Icon(Icons.person_outline, size: 42)
                        : Image.file(
                            File(photo),
                            width: 88,
                            height: 88,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.person_outline, size: 42),
                          ),
                  ),
                ),
              ),
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  TextButton(
                    onPressed: _busy ? null : _pick,
                    child: const Text('Choose photo'),
                  ),
                  if (photo != null)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              _draft?.discard();
                              setState(() {
                                _draft = null;
                                _remove = true;
                              });
                            },
                      child: const Text('Remove photo'),
                    ),
                ],
              ),
              TextField(
                controller: _name,
                enabled: !_busy,
                maxLength: 40,
                decoration: const InputDecoration(labelText: 'Display name'),
              ),
              TextField(
                controller: _bio,
                enabled: !_busy,
                maxLength: 160,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Bio (optional)'),
              ),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Save profile'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
