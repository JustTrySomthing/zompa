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
  });

  final String title;
  final int? chat;
  final String? friendName;
  final bool chatOpen, unread, paused;
  final VoidCallback? onMessage, onPause;

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
