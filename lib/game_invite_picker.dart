import 'package:flutter/material.dart';

import 'github_distribution.dart';

typedef GameInviteOption<T> = ({
  T value,
  String label,
  Widget leading,
  String? unavailable,
});

Future<T?> showGameInvitePicker<T>(
  BuildContext context, {
  required String title,
  String? detail,
  required String emptyMessage,
  required List<GameInviteOption<T>> options,
}) => showModalBottomSheet<T>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.sizeOf(context).height * .9,
  ),
  builder: (_) => _GameInvitePicker(
    title: title,
    detail: detail,
    emptyMessage: emptyMessage,
    options: options,
  ),
);

Widget gameInviteArtwork(GameRelease game) {
  if (game.id != 'drop-four' || game.build < 6) {
    return const Icon(Icons.sports_esports_outlined);
  }
  return ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: Image.asset(
      'assets/games/cats-vs-dogs.webp',
      width: 44,
      height: 44,
      fit: BoxFit.cover,
      excludeFromSemantics: true,
    ),
  );
}

class _GameInvitePicker<T> extends StatefulWidget {
  const _GameInvitePicker({
    required this.title,
    this.detail,
    required this.emptyMessage,
    required this.options,
  });

  final String title, emptyMessage;
  final String? detail;
  final List<GameInviteOption<T>> options;

  @override
  State<_GameInvitePicker<T>> createState() => _GameInvitePickerState<T>();
}

class _GameInvitePickerState<T> extends State<_GameInvitePicker<T>> {
  GameInviteOption<T>? _selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ListView(
                primary: false,
                shrinkWrap: true,
                children: [
                  Text(widget.title, style: theme.textTheme.titleLarge),
                  if (widget.detail case final detail?)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        detail,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(height: 14),
                  if (widget.options.isEmpty) Text(widget.emptyMessage),
                  for (final option in widget.options) ...[
                    _option(option, colors),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: colors.onSurfaceVariant),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _selected == null
                        ? null
                        : () => Navigator.pop(context, _selected!.value),
                    child: const Text('Invite'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _option(GameInviteOption<T> option, ColorScheme colors) {
    final selected = _selected == option;
    final enabled = option.unavailable == null;
    return Material(
      color: selected ? colors.secondaryContainer : colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        enabled: enabled,
        selected: selected,
        selectedColor: colors.onSecondaryContainer,
        onTap: enabled ? () => setState(() => _selected = option) : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: option.leading,
        title: Text(option.label),
        subtitle: option.unavailable == null ? null : Text(option.unavailable!),
        trailing: selected
            ? Icon(Icons.check_circle, color: colors.onSecondaryContainer)
            : null,
      ),
    );
  }
}
