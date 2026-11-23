import 'package:flutter/material.dart';

import 'game_audio.dart';
import 'voice_calls.dart';

class GameToolbar extends StatefulWidget implements PreferredSizeWidget {
  const GameToolbar({
    super.key,
    required this.title,
    this.chat,
    this.friendName,
    this.onMessage,
    this.chatOpen = false,
    this.unread = false,
    this.paused = false,
    this.onPause,
    required this.onHelp,
  });

  final String title;
  final int? chat;
  final String? friendName;
  final bool chatOpen, unread, paused;
  final VoidCallback? onMessage, onPause;
  final VoidCallback onHelp;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  State<GameToolbar> createState() => _GameToolbarState();
}

class _GameToolbarState extends State<GameToolbar> {
  final _owner = Object();
  VoiceCalls? _calls;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final calls = VoiceScope.of(context);
    final previous = _calls;
    _calls = calls;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (previous != calls) previous?.setGameVisible(_owner, false);
      if (mounted) calls?.setGameVisible(_owner, true);
    });
  }

  @override
  void dispose() {
    final calls = _calls;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      calls?.setGameVisible(_owner, false);
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calls = _calls;
    final chat = widget.chat;
    return AppBar(
      title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      titleSpacing: 0,
      leadingWidth: 44,
      leading: const BackButton(),
      actions: [
        if (widget.onMessage != null)
          MatchChatButton(
            open: widget.chatOpen,
            unread: widget.unread,
            onPressed: widget.onMessage!,
          ),
        if (calls != null && (chat != null || calls.busy))
          IconButton(
            tooltip: calls.busy ? 'Open call' : 'Voice call',
            onPressed: calls.busy
                ? calls.showCall
                : chat == null
                ? null
                : () => calls.dial(chat, widget.friendName ?? 'Your friend'),
            icon: Icon(calls.busy ? Icons.phone_in_talk : Icons.call_outlined),
          ),
        IconButton(
          tooltip: 'How to play',
          onPressed: widget.onHelp,
          icon: const Icon(Icons.help_outline),
        ),
        const GameAudioButton(),
        IconButton(
          tooltip: widget.paused ? 'Resume' : 'Pause',
          onPressed: widget.onPause,
          icon: Icon(widget.paused ? Icons.play_arrow : Icons.pause),
        ),
      ],
    );
  }
}

class MatchChatButton extends StatelessWidget {
  const MatchChatButton({
    super.key,
    required this.open,
    required this.unread,
    required this.onPressed,
  });

  final bool open, unread;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final highlight = unread && !open;
    return Semantics(
      liveRegion: highlight,
      child: IconButton(
        tooltip: open
            ? 'Close match chat'
            : highlight
            ? 'New message in match chat'
            : 'Open match chat',
        onPressed: onPressed,
        isSelected: open,
        selectedIcon: const Icon(Icons.chat),
        style: highlight
            ? IconButton.styleFrom(
                backgroundColor: colors.secondaryContainer,
                foregroundColor: colors.onSecondaryContainer,
              )
            : null,
        icon: Badge(
          isLabelVisible: highlight,
          smallSize: 12,
          backgroundColor: colors.error,
          child: const Icon(Icons.chat_outlined),
        ),
      ),
    );
  }
}

Future<bool?> confirmQuitMatch(
  BuildContext context, {
  required String message,
}) => showDialog<bool>(
  context: context,
  builder: (dialog) => AlertDialog(
    scrollable: true,
    title: const Text('Quit this match?'),
    content: Text(message),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialog),
        child: const Text('Keep playing'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(dialog, true),
        child: const Text('Quit match'),
      ),
    ],
  ),
);

Future<void> showGameInstructions(
  BuildContext context,
  Future<String?>? rules, {
  bool fourInARow = false,
}) async {
  final text = await rules;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('How to play'),
      content: SingleChildScrollView(
        child: Text(
          text != null && text.isNotEmpty
              ? text
              : fourInARow
              ? 'Take turns dropping a piece into a column. Connect four of your pieces horizontally, vertically, or diagonally to win the round. A full board with no line of four is a draw.'
              : 'This package does not include written instructions. Use Audio to adjust game sound and Pause to suspend play.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Back to game'),
        ),
      ],
    ),
  );
}

/// The game stays visible behind the same pause controls in every play mode.
class GamePausePanel extends StatelessWidget {
  const GamePausePanel({
    super.key,
    this.detail,
    this.onResume,
    this.onQuit,
    this.quitLabel = 'Quit match',
    this.extraActions = const [],
  });

  final String? detail;
  final VoidCallback? onResume, onQuit;
  final String quitLabel;
  final List<Widget> extraActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        const ModalBarrier(dismissible: false, color: Colors.black54),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Card(
                elevation: 12,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.pause_circle_outline,
                        size: 36,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Game paused',
                        style: theme.textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      if (detail case final message?) ...[
                        const SizedBox(height: 8),
                        Text(message, textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 18),
                      if (onResume != null)
                        FilledButton(
                          onPressed: onResume,
                          child: const Text('Resume'),
                        ),
                      if (onQuit != null)
                        TextButton(onPressed: onQuit, child: Text(quitLabel)),
                      ...extraActions,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
