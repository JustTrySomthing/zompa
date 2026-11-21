import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'tab_content.dart';

class ChatNotificationSettings extends ChangeNotifier {
  ChatNotificationSettings(this.host);

  final MethodChannel host;
  bool _disposed = false;
  bool changingMute = false;
  bool muted = false;
  bool messages = true;
  bool invites = true;
  bool calls = true;
  bool updates = true;

  Future<void> load() async {
    try {
      final values = await host.invokeMapMethod<String, bool>(
        'chatNotificationSettings',
      );
      if (values == null || _disposed) return;
      muted = values['muted'] ?? false;
      messages = values['messages'] ?? true;
      invites = values['invites'] ?? true;
      calls = values['calls'] ?? true;
      updates = values['updates'] ?? true;
      notifyListeners();
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> set(
    BuildContext context,
    String key,
    bool value, {
    bool showMuteFeedback = false,
  }) async {
    final changingMaster = key == 'muted';
    if (changingMaster && changingMute) return;
    final page = ModalRoute.of(context);
    if (changingMaster) {
      changingMute = true;
      notifyListeners();
    }
    try {
      await host.invokeMethod<void>('setChatNotification', {
        'key': key,
        'value': value,
      });
      if (_disposed) return;
      if (changingMaster) muted = value;
      await load();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t change notifications.')),
        );
      }
      return;
    } finally {
      if (changingMaster && !_disposed) {
        changingMute = false;
        notifyListeners();
      }
    }
    if (showMuteFeedback && context.mounted && page?.isCurrent != false) {
      final navigator = Navigator.of(context, rootNavigator: true);
      final feedback = DialogRoute<void>(
        context: context,
        barrierColor: Colors.transparent,
        builder: (_) => AlertDialog(
          content: Text(
            muted ? 'All notifications muted' : 'Notifications on',
            textAlign: TextAlign.center,
          ),
        ),
      );
      navigator.push(feedback);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      if (feedback.isActive) navigator.removeRoute(feedback);
    }
  }
}

class ChatChrome extends InheritedWidget {
  const ChatChrome({
    super.key,
    required this.notifications,
    required this.openContacts,
    required this.openSaved,
    required this.openSettings,
    required this.messageTextSize,
    required super.child,
  });

  final ChatNotificationSettings notifications;
  final void Function(BuildContext)? openContacts, openSaved, openSettings;
  final double messageTextSize;

  static ChatChrome? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatChrome>();

  @override
  bool updateShouldNotify(ChatChrome oldWidget) =>
      notifications != oldWidget.notifications ||
      (openContacts == null) != (oldWidget.openContacts == null) ||
      (openSaved == null) != (oldWidget.openSaved == null) ||
      (openSettings == null) != (oldWidget.openSettings == null) ||
      messageTextSize != oldWidget.messageTextSize;
}

enum ChatDestination { saved, contacts, settings }

AppBar chatPageBar(
  BuildContext context,
  String label, {
  ChatDestination? selected,
  bool showBrand = false,
  bool fitTitle = true,
  List<Widget> firstActions = const [],
  List<Widget> lastActions = const [],
}) {
  final width =
      MediaQuery.sizeOf(context).width - MediaQuery.paddingOf(context).horizontal;
  final compact = width < 380;
  final shortcuts = chatActions(context, selected: selected);
  final actionWidth =
      48.0 * (shortcuts.length + firstActions.length + lastActions.length);
  final backWidth = Navigator.canPop(context) ? (compact ? 48.0 : 56.0) : 0.0;
  final titleWidth = showBrand ? 100.0 : 72.0;
  // Keep the universal shortcuts visible even when the title and actions
  // cannot share a row with usable tap targets.
  final separateShortcuts =
      shortcuts.isNotEmpty && width < backWidth + actionWidth + titleWidth;
  final text = Text(
    label,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: showBrand ? const TextStyle(fontWeight: FontWeight.w700) : null,
  );
  final title = fitTitle
      ? FittedBox(
          alignment: AlignmentDirectional.centerStart,
          fit: BoxFit.scaleDown,
          child: text,
        )
      : text;
  return AppBar(
    titleSpacing: compact ? 4 : null,
    leadingWidth: compact ? 48 : null,
    title: showBrand
        ? Row(
            children: [
              Image.asset(
                ZompadoBrand.markAsset,
                width: 25,
                height: 25,
                excludeFromSemantics: true,
              ),
              SizedBox(width: compact ? 6 : 10),
              Flexible(
                child: TabContent(selection: label, child: title),
              ),
            ],
          )
        : title,
    actions: [
      ...firstActions,
      if (!separateShortcuts) ...shortcuts,
      ...lastActions,
    ],
    bottom: separateShortcuts
        ? PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: shortcuts,
            ),
          )
        : null,
  );
}

List<Widget> chatActions(BuildContext context, {ChatDestination? selected}) {
  final chrome = ChatChrome.of(context);
  if (chrome == null) return [];
  final colors = Theme.of(context).colorScheme;

  Widget shortcut(
    ChatDestination destination,
    String label,
    IconData icon,
    void Function(BuildContext) open,
  ) {
    if (selected == destination) {
      return Semantics(
        selected: true,
        child: IconButton.filled(
          tooltip: label,
          style: IconButton.styleFrom(
            disabledBackgroundColor: colors.secondaryContainer,
            disabledForegroundColor: colors.onSecondaryContainer,
          ),
          onPressed: null,
          icon: Icon(icon),
        ),
      );
    }
    return IconButton(
      tooltip: label,
      onPressed: () => open(context),
      icon: Icon(icon),
    );
  }

  return [
    if (chrome.openSaved case final open?)
      shortcut(ChatDestination.saved, 'Saved', Icons.star_outline, open),
    ListenableBuilder(
      listenable: chrome.notifications,
      builder: (context, _) {
        final settings = chrome.notifications;
        return IconButton(
          tooltip: settings.muted
              ? 'Unmute all notifications'
              : 'Mute all notifications',
          icon: Icon(
            settings.muted
                ? Icons.notifications_off_outlined
                : Icons.notifications_none,
          ),
          onPressed: settings.changingMute
              ? null
              : () => settings.set(
                  context,
                  'muted',
                  !settings.muted,
                  showMuteFeedback: true,
                ),
        );
      },
    ),
    if (chrome.openContacts case final open?)
      shortcut(
        ChatDestination.contacts,
        'Contacts',
        Icons.person_outline_rounded,
        open,
      ),
    if (chrome.openSettings case final open?)
      shortcut(
        ChatDestination.settings,
        'Settings',
        Icons.settings_outlined,
        open,
      ),
  ];
}

class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key, required this.settings});

  final ChatNotificationSettings settings;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: chatPageBar(context, 'Notifications'),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              title: const Text('Mute all notifications'),
              value: settings.muted,
              onChanged: settings.changingMute
                  ? null
                  : (value) => settings.set(context, 'muted', value),
            ),
            for (final (key, label, enabled) in [
              ('messages', 'Chat messages', settings.messages),
              ('invites', 'Game invites and match activity', settings.invites),
              ('calls', 'Incoming and missed calls', settings.calls),
              ('updates', 'App updates', settings.updates),
            ])
              SwitchListTile(
                title: Text(label),
                value: enabled,
                onChanged: (value) => settings.set(context, key, value),
              ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Android notification settings'),
              subtitle: const Text(
                'Manage notification permission and lock-screen visibility.',
              ),
              onTap: () =>
                  settings.host.invokeMethod<void>('openNotificationSettings'),
            ),
          ],
        ),
      ),
    ),
  );
}
