import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_avatar.dart';
import 'chat_chrome.dart';
import 'dialog_actions.dart';
import 'chat_files.dart';
import 'chat_links.dart';
import 'chat_preview.dart';
import 'chatmail.dart';
import 'game_link.dart';
import 'message_bubble.dart';
import 'online_match.dart';

class SavedMessagesPage extends StatefulWidget {
  const SavedMessagesPage({
    super.key,
    required this.chatmail,
    required this.openGame,
  });
  final Chatmail chatmail;
  final Future<void> Function(GameLink) openGame;

  @override
  State<SavedMessagesPage> createState() => _SavedMessagesPageState();
}

class _SavedMessagesPageState extends State<SavedMessagesPage> {
  String _query = '', _filter = 'All';
  List<FriendMessage> _messages = [];
  bool _loading = true, _failed = false;
  int _request = 0;
  Timer? _refresh;
  StreamSubscription<void>? _events;

  @override
  void initState() {
    super.initState();
    _events = widget.chatmail.changes.listen((_) {
      _refresh?.cancel();
      _refresh = Timer(const Duration(milliseconds: 240), _load);
    });
    _load();
  }

  @override
  void dispose() {
    _events?.cancel();
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      final ready = await widget.chatmail.restore();
      final entries = ready
          ? await widget.chatmail.savedMessages()
          : <FriendMessage>[];
      if (mounted && request == _request)
        setState(() {
          _messages = entries.where((message) => !message.info).toList();
          _loading = false;
          _failed = false;
        });
    } catch (_) {
      if (mounted && request == _request)
        setState(() {
          _loading = false;
          _failed = true;
        });
    }
  }

  String _category(FriendMessage message) {
    if (GameLink.parse(message.text) != null ||
        MatchEvent.parse(message.text) != null)
      return 'Games';
    if (message.file != null) {
      return switch (message.mime?.split('/').first) {
        'image' => 'Photos',
        'video' => 'Videos',
        'audio' => 'Audio',
        _ => 'Files',
      };
    }
    return chatLinks(message.text).isNotEmpty ? 'Links' : 'Messages';
  }

  @override
  Widget build(BuildContext context) {
    final entries = _messages.where((message) {
      if (_filter != 'All' && _category(message) != _filter) return false;
      return '${message.text} ${message.filename ?? ''} ${message.sender?.name ?? ''}'
          .toLowerCase()
          .contains(_query);
    }).toList();
    return Scaffold(
      appBar: chatPageBar(context, 'Saved', selected: ChatDestination.saved),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: 'Search saved messages',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (value) =>
                          setState(() => _query = value.trim().toLowerCase()),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final name in [
                          'All',
                          'Messages',
                          'Photos',
                          'Videos',
                          'Audio',
                          'Files',
                          'Links',
                          'Games',
                        ])
                          ChoiceChip(
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            label: Text(name),
                            showCheckmark: false,
                            selected: _filter == name,
                            onSelected: (_) => setState(() => _filter = name),
                          ),
                      ],
                    ),
                  ),
                  if (_loading) const LinearProgressIndicator(),
                  if (_failed)
                    TextButton(
                      onPressed: _load,
                      child: const Text('Couldn’t load saved messages. Retry'),
                    ),
                ],
              ),
            ),
            if (entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    _loading || _failed
                        ? ''
                        : _query.isEmpty && _filter == 'All'
                        ? 'Star a message to save it here.'
                        : 'No matching saved messages.',
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                sliver: SliverList.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final message = entries[index];
                    final game = GameLink.parse(message.text);
                    final name = message.sender?.name ?? 'Saved message';
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                ChatAvatar(
                                  name,
                                  photo: message.sender?.photo,
                                  radius: 14,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    chatTime(context, message.timestamp),
                                    textAlign: TextAlign.end,
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.star,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                                  tooltip: 'Remove saved copy',
                                  onPressed: () => showMessageActions(
                                    context,
                                    widget.chatmail,
                                    message,
                                    saved: true,
                                  ),
                                ),
                              ],
                            ),
                            if (message.file case final path?
                                when _category(message) == 'Photos')
                              Image.file(
                                File(path),
                                cacheWidth: 640,
                                width: double.infinity,
                                height: 138,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox.shrink(),
                              ),
                            if (game != null)
                              TextButton.icon(
                                onPressed: () => widget.openGame(game),
                                icon: const Icon(Icons.sports_esports_outlined),
                                label: const Text('Open game'),
                              )
                            else if (MatchEvent.parse(message.text) != null)
                              const Text('Cats vs Dogs match invitation')
                            else if (message.text.isNotEmpty)
                              ChatText(
                                message.text,
                                size:
                                    ChatChrome.of(context)?.messageTextSize ??
                                    defaultMessageTextSize,
                              ),
                            if (message.file != null)
                              TextButton.icon(
                                onPressed: () =>
                                    downloadChatFile(context, message),
                                icon: const Icon(Icons.download),
                                label: Text(
                                  message.filename ?? 'Download attachment',
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> downloadChatFile(
  BuildContext context,
  FriendMessage message,
) async {
  final file = message.file;
  if (file == null) return;
  try {
    final saved = await ChatFile.download(
      file,
      message.filename ?? 'Attachment',
      message.mime,
    );
    if (saved && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('File saved.')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Couldn’t save this file.')));
    }
  }
}

Future<void> showMessageActions(
  BuildContext context,
  Chatmail chatmail,
  FriendMessage message, {
  bool saved = false,
}) async {
  final action = await showDialog<String>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(saved ? 'Saved message' : 'Message options'),
      children: [
        if (message.text.isNotEmpty && MatchEvent.parse(message.text) == null)
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Copy text'),
            onTap: () => Navigator.pop(dialog, 'copy'),
          ),
        if (message.file != null)
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Download file'),
            onTap: () => Navigator.pop(dialog, 'download'),
          ),
        if (message.chat > 0 && !message.outgoing && !saved)
          ListTile(
            leading: const Icon(Icons.alarm_add_outlined),
            title: const Text('Remind me later'),
            onTap: () => Navigator.pop(dialog, 'remind'),
          ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text(saved ? 'Remove saved copy' : 'Delete message'),
          onTap: () => Navigator.pop(dialog, 'delete'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  if (action == 'copy') {
    await Clipboard.setData(ClipboardData(text: message.text));
  } else if (action == 'download') {
    await downloadChatFile(context, message);
  } else if (action == 'remind') {
    await showReplyReminder(context, message);
  } else if (action == 'delete') {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: Text(saved ? 'Remove saved copy?' : 'Delete this message?'),
        content: Text(
          saved
              ? 'Remove this message from Saved.'
              : 'Remove this message from your chat history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: saved ? null : destructiveDialogAction(dialog),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(saved ? 'Remove' : 'Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await chatmail.deleteMessage(message.id);
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t remove this message.')),
        );
    }
  }
}

Future<void> showReplyReminder(
  BuildContext context,
  FriendMessage message,
) async {
  final delay = await showDialog<Duration>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: const Text('Remind me to reply'),
      children: [
        for (final (label, delay) in const [
          ('In 1 hour', Duration(hours: 1)),
          ('In 1 day', Duration(days: 1)),
          ('In 1 week', Duration(days: 7)),
        ])
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog, delay),
            child: Text(label),
          ),
      ],
    ),
  );
  if (delay == null || !context.mounted) return;
  var scheduled = false;
  try {
    scheduled =
        await const MethodChannel('io.zompado.host')
            .invokeMethod<bool>('remindToReply', {
              'chat': message.chat,
              'message': message.id,
              'delay': delay.inMilliseconds,
            }) ==
        true;
  } on PlatformException {
    // Show a useful result when Android declines to schedule the reminder.
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        scheduled ? 'Reply reminder set.' : 'Couldn’t set a reply reminder.',
      ),
    ),
  );
}
