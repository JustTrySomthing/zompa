import 'chat_chrome.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SetupPage extends StatefulWidget {
  const SetupPage({
    super.key,
    required this.host,
    required this.onDone,
    this.firstRun = false,
  });

  final MethodChannel host;
  final VoidCallback onDone;
  final bool firstRun;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> with WidgetsBindingObserver {
  Map<String, bool>? _status;
  bool _working = false;
  bool _statusFailed = false;
  int _refreshId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final id = ++_refreshId;
    try {
      final status = await widget.host.invokeMapMethod<String, bool>(
        'setupStatus',
      );
      if (mounted && id == _refreshId) {
        setState(() {
          _status = status;
          _statusFailed = status == null;
        });
      }
    } on PlatformException {
      if (mounted && id == _refreshId) setState(() => _statusFailed = true);
    } on MissingPluginException {
      if (mounted && id == _refreshId) setState(() => _statusFailed = true);
    }
  }

  Future<void> _open(String method) async {
    setState(() => _working = true);
    try {
      await widget.host.invokeMethod<void>(method);
      await _refresh();
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t open Android settings. Try again.'),
          ),
        );
      }
    } on MissingPluginException {
      if (mounted) setState(() => _statusFailed = true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Setup'), actions: chatActions(context)),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _GuideHeader(
            icon: Icons.tune_rounded,
            title: widget.firstRun ? 'Welcome to Zompado' : 'Set up Zompado',
            text: 'Choose what Zompado can access.',
          ),
          const SizedBox(height: 16),
          const _SetupCard(
            icon: Icons.language_rounded,
            title: 'Internet access',
            text: 'Already enabled for chats, downloads, and updates.',
          ),
          _SetupCard(
            icon: Icons.notifications_active_outlined,
            title: 'Notifications',
            text: 'Get alerts for messages, calls, matches, and updates.',
            enabled: _status?['notifications'],
            action: !_working && _status?['notifications'] == false
                ? () => _open('requestUpdateNotifications')
                : null,
            button: 'Allow alerts',
          ),
          _SetupCard(
            icon: Icons.lock_outline,
            title: 'Lock-screen alerts',
            text: 'Allow Zompado notifications on the lock screen in Android settings.',
            action: !_working ? () => _open('openNotificationSettings') : null,
            button: 'Open notification settings',
          ),
          _SetupCard(
            icon: Icons.mic_none_outlined,
            title: 'Microphone for voice calls',
            text: 'Let friends hear you during calls.',
            enabled: _status?['microphone'],
            action: !_working && _status?['microphone'] == false
                ? () => _open('requestMicrophone')
                : null,
            button: 'Allow microphone',
          ),
          _SetupCard(
            icon: Icons.camera_alt_outlined,
            title: 'Camera for QR codes and calls',
            text: _status?['cameraAvailable'] == false
                ? 'Paste invite links in Contacts.'
                : 'Scan invite codes or use video in calls.',
            enabled: _status?['camera'],
            action:
                !_working &&
                    _status?['cameraAvailable'] == true &&
                    _status?['camera'] == false
                ? () => _open('requestCamera')
                : null,
            button: 'Allow camera',
          ),
          _SetupCard(
            icon: Icons.system_update_alt_rounded,
            title: 'Install updates from Zompado',
            text: 'Open Android’s installer when an update is ready.',
            enabled: _status?['updateInstall'],
            action: !_working && _status?['updateInstall'] == false
                ? () => _open('openUpdateInstallSettings')
                : null,
            button: 'Open Android settings',
          ),
          if (_statusFailed)
            TextButton(
              onPressed: _working ? null : _refresh,
              child: const Text('Couldn’t check permissions. Tap to retry.'),
            ),
          const SizedBox(height: 8),
          const Text(
            'These permissions are optional. You can return to Setup any time.',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _working ? null : widget.onDone,
            child: Text(widget.firstRun ? 'Finish setup' : 'Done'),
          ),
        ],
      ),
    ),
  );
}

class _GuideHeader extends StatelessWidget {
  const _GuideHeader({
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: colors.primaryContainer,
              foregroundColor: colors.onPrimaryContainer,
              child: Icon(icon),
            ),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(text),
          ],
        ),
      ),
    );
  }
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({
    required this.icon,
    required this.title,
    required this.text,
    this.enabled,
    this.action,
    this.button,
  });

  final IconData icon;
  final String title;
  final String text;
  final bool? enabled;
  final VoidCallback? action;
  final String? button;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(text),
            if (enabled != null || action != null) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (enabled != null)
                    Text(enabled! ? 'Enabled' : 'Optional · Off'),
                  if (action != null)
                    OutlinedButton(onPressed: action, child: Text(button!)),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

const _topics = [
  (
    icon: Icons.sports_esports_outlined,
    title: 'Find, install, and play games',
    description: 'Game catalog, solo play, and taking turns',
    answers: [
      (
        'Where do I find games?',
        'Open Games → Get Games to browse the official catalog. Choose a game to install it, then open it from your library.',
      ),
      (
        'How do I share or open a game?',
        'Tap Share game on Cats vs Dogs in My Games. Open a game card from the chat, or paste a shared link under Games → Open game link. Zompado checks the exact version before offering to install it.',
      ),
      (
        'How do I play Cats vs Dogs with a friend online?',
        'Tap the gamepad in a friend chat, choose an installed game that supports online matches, then tap Invite. Your friend taps Accept on the invite. Zompado downloads the game if needed. The inviter taps Play Now to start both boards and takes the first turn. Open My Games → Active Games to see who you’re playing and whose turn it is. Tap Resume Game to return to the board or End game to close a match for both players. Unanswered invitations expire after 7 days. Games with no moves for 30 days leave Active Games. If a new game would take you over 12 active games, the least recently played game leaves the list.',
      ),
      (
        'How do I change game sounds?',
        'Open Settings → Game audio or tap the speaker icon while playing. Game volume starts at 20% until you change it. Each slider has its own mute button, which keeps that slider’s level. Zompado lowers game volume during voice calls by default and restores it when the call ends. Separate Music and Sound effects sliders work with games that use the Zompado SDK.',
      ),
      (
        'How do I remove a downloaded game?',
        'Open My Games, tap the menu on the game, then tap Remove. This removes its download and keeps its save files.',
      ),
      (
        'Can I import a game file?',
        'Open Games → Import a Game and choose a .zomp or .love file. Then tap Play next to its name. Zompado runs compatible LÖVE 11.5 games. A game that needs a native extension or online access may not run. Official catalog games use .zomp.',
      ),
      (
        'Can I play with someone next to me?',
        'Choose Pass & Play to take turns on one device. Choose Single Player to play against the computer.',
      ),
      (
        'How do I pause or leave a game?',
        'Tap Pause in the game toolbar to take a break or choose Quit game. In an online match, a pause applies to both players, and the player who paused can resume. Quitting ends the match for both players.',
      ),
      (
        'Can I talk to my friend while playing?',
        'During an online match, tap the message button to open chat. Tap the bar at the bottom of the chat panel to close it. New messages briefly appear at the bottom of the board while chat is closed. Tap the phone to start a call. Use Return to game to keep talking while you play, then tap the phone again to reopen the call controls.',
      ),
    ],
  ),
  (
    icon: Icons.forum_outlined,
    title: 'Connect and chat with friends',
    description: 'Profiles, friend invites, and messages',
    answers: [
      (
        'How do I connect with a friend?',
        'Open Chats and create a profile. Open Contacts from the top bar. Tap Create Invite to share your link, or Accept Invite to scan or paste a friend’s link. On the other phone, open Contacts → Accept Invite and scan the QR code or paste the link. Allow camera access when prompted or in Settings → Setup.',
      ),
      (
        'How do I manage contacts?',
        'Tap Contacts in the top bar. Search by name, or tap the pin to keep someone at the top. Use the menu to block or delete them. Turn on Show blocked contacts to unblock someone.',
      ),
      (
        'How do I edit my profile?',
        'Open Settings → My Profile to change your name, photo, or optional bio.',
      ),
      (
        'How do I make messages easier to read?',
        'Open Settings → Appearance to choose Light mode or Dark mode. Choose from 18 swatches under Accent color. Royal Blue is the default. Use Message text size to adjust the text inside chat bubbles.',
      ),
      (
        'Where can I get a log if a call is slow or crashes?',
        'Reopen Zompado and go to Settings → App Log. Tap Copy Log to share the recorded call stages and available Android crash details. Tap Clear Log to erase the entries.',
      ),
      (
        'How do I call a friend?',
        'Open a friend’s conversation and tap the phone icon. Check their name, then tap Call. Allow microphone access to speak. The bottom controls let you mute the microphone, switch between handset and speaker, switch between Video and Audio, or end the call. When your camera is on, Preview shows or hides your own picture. For the quickest incoming alerts, keep Zompado running. If Android’s scheduled check finds a call that’s still ringing, tap the alert to answer it in Zompado.',
      ),
      (
        'How do I send files or keep their original quality?',
        'Use the paperclip to capture or attach media. Settings → Compression lets you choose Balanced or Data saver. Use Attach Original File to send the original bytes.',
      ),
      (
        'Can I play media in chat?',
        'GIFs play in the conversation. Tap a photo to enlarge and zoom it, Play video to watch an attachment, or the audio play button to listen in chat. Tap a YouTube preview to play it. Website addresses like example.com open in Preview Browser, even without https://. Use the top-right button to open the page in your default browser.',
      ),
      (
        'How do I restore a deleted chat or set a reply reminder?',
        'Go to Chats → Trash to restore conversations or permanently empty Trash. Long-press a chat and choose Remind me later for its latest incoming message, or set a reminder from a specific message.',
      ),
      (
        'How do I move my chats to a new phone?',
        'Open Settings → Backup to save your Chatmail profile, messages, and attachments in a password-protected file. On the new phone, complete Zompado Setup and choose Restore backup before creating a chat profile.',
      ),
      (
        'Where are my saved messages?',
        'Tap the star on a message to save it. Tap Saved in the top bar to search and filter your saved messages and attachments.',
      ),
      (
        'When can I send a message?',
        'Open your friend’s conversation after the connection is ready. Messages waiting on the connection show Sending. A failed message shows Couldn’t send.',
      ),
    ],
  ),
  (
    icon: Icons.shield_outlined,
    title: 'Setup and permissions',
    description: 'Internet, alerts, and Android settings',
    answers: [
      (
        'How do I open Setup again?',
        'Open Settings → Setup. You can turn on notifications or open Android’s installation settings there.',
      ),
      (
        'Does Zompado need my location?',
        'The current game catalog, games, and link-based chat setup work without location access. Android handles internet access automatically.',
      ),
      (
        'What alerts can I turn on?',
        'Open Settings → Notifications for alert categories and Android lock screen settings. Tap the bell in the top bar to mute all Zompado alerts. Choose Quiet Hours to schedule when alerts arrive silently. Tap a message alert to open the chat or a turn alert to open its match. When Android closes the app process, it checks for activity periodically and may delay alerts. If you use Force stop, open Zompado again to resume checks.',
      ),
    ],
  ),
  (
    icon: Icons.system_update_alt_rounded,
    title: 'Keep Zompado up to date',
    description: 'Check for a new version and install it',
    answers: [
      (
        'Where do I check for updates?',
        'Open Settings → Check for updates. If a version is available, tap Update and follow Android’s installation prompt.',
      ),
      (
        'Why is Android asking about this source?',
        'Android may ask you to allow Zompado to open the installer. You can change that in Settings → Setup → Install updates from Zompado.',
      ),
    ],
  ),
];

class HelpPage extends StatefulWidget {
  const HelpPage({super.key});

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final search = _query.trim().toLowerCase();
    final topics = _topics
        .where(
          (topic) => '${topic.title} ${topic.description} ${topic.answers}'
              .toLowerCase()
              .contains(search),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Help'), actions: chatActions(context)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const _GuideHeader(
              icon: Icons.help_outline_rounded,
              title: 'How can we help?',
              text: 'Find quick answers about games, friends, and setting up Zompado.',
            ),
            const SizedBox(height: 14),
            TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search help',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            if (topics.isEmpty)
              const Text('No results. Try “games”, “invite”, or “updates”.'),
            for (final topic in topics)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    key: ValueKey((topic.title, search.isNotEmpty)),
                    initiallyExpanded: search.isNotEmpty,
                    leading: Icon(topic.icon),
                    title: Text(topic.title),
                    subtitle: Text(topic.description),
                    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                    childrenPadding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    children: [
                      for (final (question, answer) in topic.answers)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                question,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(answer),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
