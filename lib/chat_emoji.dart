import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<Map<String, List<(String, String)>>>? _catalog;

Future<Map<String, List<(String, String)>>> _loadEmoji() async {
  final entries =
      jsonDecode(await rootBundle.loadString('assets/chat/emoji.json')) as List;
  final categories = <String, List<(String, String)>>{};
  for (final row in entries.cast<Map<String, dynamic>>()) {
    (categories[row['category'] as String] ??= []).add((
      row['emoji'] as String,
      row['name'] as String,
    ));
  }
  return categories;
}

class ChatEmojiPicker extends StatefulWidget {
  const ChatEmojiPicker({super.key, required this.insert});
  final ValueChanged<String> insert;

  @override
  State<ChatEmojiPicker> createState() => _ChatEmojiPickerState();
}

class _ChatEmojiPickerState extends State<ChatEmojiPicker> {
  String? _selected;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: 290,
      child: FutureBuilder(
        future: _catalog ??= _loadEmoji(),
        builder: (context, snapshot) {
          final groups = snapshot.data;
          if (groups == null) {
            return Center(
              child: snapshot.hasError
                  ? const Text('Couldn’t load emojis.')
                  : const CircularProgressIndicator(),
            );
          }
          final selected = _selected ?? groups.keys.first;
          return Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final category in groups.keys)
                      ChoiceChip(
                        label: Text(category),
                        selected: selected == category,
                        onSelected: (_) => setState(() => _selected = category),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.extent(
                  key: ValueKey(selected),
                  maxCrossAxisExtent: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final (emoji, label) in groups[selected]!)
                      TextButton(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: () => widget.insert(emoji),
                        child: Text(
                          emoji,
                          semanticsLabel: label,
                          style: const TextStyle(fontSize: 23),
                        ),
                      ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
