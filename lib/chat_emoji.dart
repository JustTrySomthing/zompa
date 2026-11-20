import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
  const ChatEmojiPicker({
    super.key,
    required this.insert,
    this.draft,
    this.single = false,
  });
  final ValueListenable<TextEditingValue>? draft;
  final bool single;
  final ValueChanged<String> insert;

  @override
  State<ChatEmojiPicker> createState() => _ChatEmojiPickerState();
}

class _ChatEmojiPickerState extends State<ChatEmojiPicker> {
  String? _selected;
  String? _emoji;

  void _pick(String emoji) {
    setState(() => _emoji = emoji);
    if (!widget.single) widget.insert(emoji);
  }

  Widget _preview(BuildContext context, String value) => Container(
    margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
    padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
    width: double.infinity,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      value.isEmpty
          ? (widget.single ? 'Choose a reaction' : 'Selected emoji appear here')
          : value,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 17),
    ),
  );

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
              if (widget.draft case final draft?)
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: draft,
                  builder: (context, value, _) => _preview(context, value.text),
                )
              else
                _preview(context, _emoji ?? ''),
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
                      _EmojiTile(
                        emoji: emoji,
                        label: label,
                        selected: widget.single && _emoji == emoji,
                        onTap: () => _pick(emoji),
                      ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: widget.single && _emoji == null
                      ? null
                      : () {
                          if (widget.single) widget.insert(_emoji!);
                          Navigator.pop(context);
                        },
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

class _EmojiTile extends StatefulWidget {
  const _EmojiTile({
    required this.emoji,
    required this.label,
    required this.onTap,
    required this.selected,
  });
  final String emoji, label;
  final VoidCallback onTap;
  final bool selected;

  @override
  State<_EmojiTile> createState() => _EmojiTileState();
}

class _EmojiTileState extends State<_EmojiTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    child: Material(
      color: widget.selected
          ? Theme.of(context).colorScheme.secondaryContainer
          : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onHighlightChanged: (value) => setState(() => _pressed = value),
        onTap: widget.onTap,
        child: Center(
          child: AnimatedScale(
            duration: Duration(milliseconds: _pressed ? 55 : 140),
            curve: Curves.easeOutCubic,
            scale: _pressed ? .74 : 1,
            child: ExcludeSemantics(
              child: Text(widget.emoji, style: const TextStyle(fontSize: 23)),
            ),
          ),
        ),
      ),
    ),
  );
}
