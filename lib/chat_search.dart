import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_preview.dart';
import 'chatmail.dart';

class ChatSearchPage extends StatefulWidget {
  const ChatSearchPage({
    super.key,
    required this.chatmail,
    required this.chat,
    required this.name,
  });

  final Chatmail chatmail;
  final int chat;
  final String name;

  @override
  State<ChatSearchPage> createState() => _ChatSearchPageState();
}

class _ChatSearchPageState extends State<ChatSearchPage> {
  String _query = '';
  int _request = 0;
  Timer? _debounce;
  List<FriendMessage>? _results;
  bool _failed = false;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search(String value) {
    final term = value.trim();
    final request = ++_request;
    _debounce?.cancel();
    setState(() {
      _query = term;
      _results = null;
      _failed = false;
    });
    if (term.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final results = await widget.chatmail.searchConversation(
          widget.chat,
          term,
        );
        if (mounted && _request == request) setState(() => _results = results);
      } catch (_) {
        if (mounted && _request == request) setState(() => _failed = true);
      }
    });
  }

  String _messageText(FriendMessage message) =>
      message.bubbleCaption.trim().isEmpty
      ? message.filename ?? 'Attachment'
      : message.bubbleCaption;

  String _messageDate(BuildContext context, FriendMessage message) {
    final date = DateTime.fromMillisecondsSinceEpoch(message.timestamp * 1000);
    final day = MaterialLocalizations.of(context).formatShortDate(date);
    return '${message.outgoing ? 'You' : widget.name} · $day';
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    return Scaffold(
      appBar: AppBar(title: const Text('Search conversation')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Column(
            children: [
              TextField(
                autofocus: true,
                onChanged: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: 'Search with ${widget.name}',
                ),
              ),
              Expanded(
                child: _query.isEmpty
                    ? const SizedBox.shrink()
                    : _failed
                    ? Center(
                        child: TextButton(
                          onPressed: () => _search(_query),
                          child: const Text('Couldn’t search. Retry'),
                        ),
                      )
                    : results == null
                    ? const Align(
                        alignment: Alignment.topCenter,
                        child: LinearProgressIndicator(),
                      )
                    : results.isEmpty
                    ? const Center(child: Text('No matching messages'))
                    : ListView.builder(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount:
                            results.length + (results.length == 50 ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == results.length) {
                            return const ListTile(
                              title: Text(
                                'Showing up to 50 results. Refine your search to find older messages.',
                              ),
                            );
                          }
                          final message = results[index];
                          return ListTile(
                            title: Text(
                              _messageText(message),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(_messageDate(context, message)),
                            onTap: () => _openMessage(message),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openMessage(FriendMessage message) {
    FocusScope.of(context).unfocus();
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_messageDate(context, message)),
          scrollable: true,
          content: ChatText(_messageText(message), size: 16),
          actions: [
            if (message.file != null && message.media != null)
              TextButton(
                onPressed: () => openChatAttachment(context, message),
                child: const Text('Open attachment'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
