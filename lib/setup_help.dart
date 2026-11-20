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
    appBar: AppBar(title: const Text('Setup')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _GuideHeader(
            icon: Icons.tune_rounded,
            title: widget.firstRun ? 'Welcome to Zompado' : 'Set up Zompado',
            text:
                'Get ready to play. You can change these choices any time in Settings → Setup.',
          ),
          const SizedBox(height: 16),
          const _SetupCard(
            icon: Icons.language_rounded,
            title: 'Internet access',
            text:
                'Android already allows Zompado to connect for game downloads, chats, and updates. Installed solo games can be played offline.',
          ),
          _SetupCard(
            icon: Icons.notifications_active_outlined,
            title: 'Notifications',
            text:
                'Get alerts for messages, calls, matches, and app updates. After Android closes Zompado, friend activity alerts can arrive on the next scheduled check.',
            enabled: _status?['notifications'],
            action: !_working && _status?['notifications'] == false
                ? () => _open('requestUpdateNotifications')
                : null,
            button: 'Allow alerts',
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
            icon: Icons.system_update_alt_rounded,
            title: 'Install updates from Zompado',
            text:
                'Allow Zompado to open Android’s installer for future updates. Android still asks you to confirm each installation.',
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
            'Alerts and in-app installation are optional. You can use Zompado with either turned off.',
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
        'Tap Share game on Drop Four in My Games, or tap the game icon in a friend chat. Open a game card from the chat, or paste a shared link under Games → Open game link. Zompado checks the exact version before offering to install it.',
      ),
      (
        'How do I play Drop Four with a friend online?',
        'Install Drop Four, open a friend chat, and tap Invite to a Drop Four match. Your friend opens the match card and accepts. You take the first turn. Resume from the match card or from Your turn in My Games. Tap the chat bubble on the board to talk to your friend.',
      ),
      (
        'How do I change game sounds?',
        'Open Settings → Game audio or tap the speaker icon while playing. Game volume controls all game audio. Separate Music and Sound effects sliders work with games that use the Zompado SDK.',
      ),
      (
        'How do I remove a downloaded game?',
        'Open My Games, tap the menu on the game, then tap Remove. This removes its download and keeps its save files.',
      ),
      (
        'Can I import my own .love game?',
        'Open Games → Import a .love game, choose the file, then tap Play next to its name. Official catalog games use .zomp.',
      ),
      (
        'Can I play with someone next to me?',
        'In Drop Four, choose Pass and play to take turns on one phone. Choose Play solo to play against the computer.',
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
        'Open Chats and create a profile. Tap Invite friend to copy or share your invite link. On the other phone, open Chats → Accept invite and scan the QR code or paste the link. Camera scanning uses Google Play services.',
      ),
      (
        'How do I call a friend?',
        'Open a friend’s conversation and tap the phone icon. Allow microphone access to speak. The call bar includes microphone mute, speaker, and End call. Keep Zompado running to receive a live incoming call.',
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
        'Setup offers app update and friend activity alerts. When Android closes the app process, it checks for activity periodically and may delay alerts. If you use Force stop, open Zompado again to resume checks.',
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
      appBar: AppBar(title: const Text('Help')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const _GuideHeader(
              icon: Icons.help_outline_rounded,
              title: 'How can we help?',
              text:
                  'Find quick answers about games, friends, and setting up Zompado.',
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
