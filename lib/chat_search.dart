import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_preview.dart';
import 'chatmail.dart';

class ConversationSearchResults extends StatefulWidget {
  const ConversationSearchResults({
    super.key,
    required this.chatmail,
    required this.chat,
    required this.name,
    required this.query,
  });

  final Chatmail chatmail;
  final int chat;
  final String name, query;

  @override
  State<ConversationSearchResults> createState() =>
      _ConversationSearchResultsState();
}

class _ConversationSearchResultsState extends State<ConversationSearchResults> {
  int _request = 0;
  Timer? _debounce;
  List<FriendMessage>? _results;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void didUpdateWidget(ConversationSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != oldWidget.query) _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search() {
    final term = widget.query;
    final request = ++_request;
    _debounce?.cancel();
    _results = null;
    _failed = false;
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
    if (_failed) {
      return Center(
        child: TextButton(
          onPressed: () => setState(_search),
          child: const Text('Couldn’t search. Retry'),
        ),
      );
    }
    if (results == null) {
      return const Align(
        alignment: Alignment.topCenter,
        child: LinearProgressIndicator(),
      );
    }
    if (results.isEmpty) {
      return const Center(child: Text('No matching messages'));
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: results.length + (results.length == 50 ? 1 : 0),
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
