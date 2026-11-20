import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart';

import 'brand.dart';
import 'app_updates.dart';
import 'github_distribution.dart';
import 'game_link.dart';
import 'chatmail.dart';
import 'friends.dart';
import 'profile_page.dart';
import 'setup_help.dart';
import 'online_matches.dart';
import 'online_match.dart';
import 'online_match_page.dart';
import 'love_imports.dart';
import 'game_play_page.dart';
import 'game_audio.dart';
import 'voice_calls.dart';

const gold = Color(0xffffdc71);
const lilac = Color(0xffc9b7ff);
const bridge = MethodChannel('io.zompado.host');
typedef ChatAlertTarget = ({int chat, int message});

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString(
      'assets/licenses/Chatmail-Core-MPL-2.0.txt',
    );
    yield LicenseEntryWithLineBreaks(const ['Chatmail Core'], license);
    final rtc = await rootBundle.loadString('assets/licenses/WebRTC-BSD.txt');
    yield LicenseEntryWithLineBreaks(const ['WebRTC'], rtc);
    final love = await rootBundle.loadString('assets/licenses/love-11.5.txt');
    yield LicenseEntryWithLineBreaks(const ['LÖVE and dependencies'], love);
    final port = await rootBundle.loadString('assets/licenses/love.js-MIT.txt');
    yield LicenseEntryWithLineBreaks(const ['love.js'], port);
    final scanner = await rootBundle.loadString(
      'assets/licenses/ZXing-Apache-2.0.txt',
    );
    yield LicenseEntryWithLineBreaks(const [
      'ZXing and JourneyApps Barcode Scanner',
    ], scanner);
  });
  runApp(const Zompado());
}

class Zompado extends StatefulWidget {
  const Zompado({super.key});
  @override
  State<Zompado> createState() => _ZompadoState();
}

class _ZompadoState extends State<Zompado> with WidgetsBindingObserver {
  ThemeMode mode = ThemeMode.dark;
  File? storage;
  Map<String, dynamic> data = {};
  Future<void> pendingWrite = Future.value();
  GithubDistribution? distribution;
  AppUpdates? updates;
  Chatmail? chatmail;
  VoiceCalls? _voice;
  GameAudio? _gameAudio;
  int _openChats = 0;
  ChatAlertTarget? _chatAlertTarget;
  StreamSubscription<(int, int)>? _incoming;
  bool get _background =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    bridge.setMethodCallHandler((call) async {
      if (call.method == 'voiceStatus') {
        _voice?.mediaEvent(call.arguments);
      } else if (call.method == 'openChats') {
        await _openChatsIfRequested();
      }
    });
    load();
  }

  Future<void> load() async {
    try {
      final path = await bridge.invokeMethod<String>('dataPath');
      if (path != null) {
        storage = File('$path/profile.json');
        final core = await bridge.invokeMethod<String>('chatmailExecutable');
        if (mounted && core != null) {
          final chat = Chatmail(core, Directory('$path/chatmail'));
          chatmail = chat;
          _voice = VoiceCalls(chat, bridge);
          _incoming = chat.incoming.listen((event) {
            if (_background) unawaited(_chatAlert(chat, event.$1, event.$2));
          });
        }
        if (await storage!.exists()) {
          data = Map<String, dynamic>.from(
            jsonDecode(await storage!.readAsString()),
          );
          mode = data['theme'] == 'light' ? ThemeMode.light : ThemeMode.dark;
        }
      }
    } catch (e) {
      debugPrint('Could not load local preferences: $e');
    }
    await _openChatsIfRequested();
    if (!mounted) return;
    final file = storage;
    if (file != null) {
      distribution = GithubDistribution(file.parent);
      updates = AppUpdates(distribution!, bridge, data, write)
        ..addListener(updateChanged);
      updates!.syncSchedule();
      updates!.checkIfDue();
    }
    setState(() {
      _gameAudio = GameAudio(data, write);
      loaded = true;
    });
  }

  Future<void> _openChatsIfRequested() async {
    try {
      final voice = _voice;
      if (!mounted || voice == null) return;
      final alert = await bridge.invokeMapMethod<String, Object>(
        'takeChatAlert',
      );
      if (!mounted || alert == null) return;
      ChatAlertTarget? target;
      if ((alert['chat'], alert['message']) case (
        final int chat,
        final int id,
      )) {
        if (alert['incomingCall'] == true) {
          unawaited(voice.restoreIncoming(chat, id));
        } else {
          target = (chat: chat, message: id);
        }
      }
      setState(() {
        _chatAlertTarget = target;
        _openChats++;
      });
    } catch (_) {
      // The desktop preview has no Android notification intent.
    }
  }

  Future<void> _chatAlert(Chatmail chatmail, int chat, int id) async {
    try {
      final message = (await chatmail.notificationMessage(chat, id))?.message;
      if (message == null || !mounted || !_background) return;
      final event = message.encrypted ? MatchEvent.parse(message.text) : null;
      var label = 'New message';
      if (event != null) {
        switch (event.kind) {
          case 'invite':
            label = 'New game invitation';
          case 'preparing':
            label = 'Your friend is getting the game ready';
          case 'accept':
            label = 'Your friend is ready to play';
          case 'decline':
            label = 'Game invitation declined';
          case 'quit':
            label = 'Your friend ended the match';
          case 'move':
            final history = await chatmail.matchHistory(chat, event.id);
            if (OnlineMatch.replay(event.id, history)?.myTurn != true) return;
            label = 'Your turn in Cats vs Dogs';
          default:
            return;
        }
      }
      if (!mounted || !_background) return;
      await bridge.invokeMethod<void>('showChatNotification', {
        'chat': chat,
        'message': id,
        'label': label,
      });
    } catch (_) {
      // Receiving a message still works when Android suppresses its alert.
    }
  }

  void finishSetup() {
    write('setupComplete', true);
    setState(() {});
  }

  void updateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) updates?.checkIfDue();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    updates?.dispose();
    _incoming?.cancel();
    bridge.setMethodCallHandler(null);
    _voice?.dispose();
    _gameAudio?.dispose();
    chatmail?.close();
    super.dispose();
  }

  void write(String key, dynamic value) {
    data[key] = value;
    final file = storage;
    if (file == null) return;
    final snapshot = jsonEncode(data);
    pendingWrite = pendingWrite
        .then((_) async {
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(snapshot, flush: true);
          await temporary.rename(file.path);
        })
        .catchError((Object error) => debugPrint('Could not save: $error'));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zompado',
      debugShowCheckedModeBanner: false,
      theme: ZompadoBrand.theme(Brightness.light),
      darkTheme: ZompadoBrand.theme(Brightness.dark),
      builder: (context, child) {
        final launch = BrandLaunch(
          child: _voice == null
              ? child!
              : VoiceScope(
                  calls: _voice!,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [child!, const VoicePanel()],
                  ),
                ),
        );
        final audio = _gameAudio;
        return audio == null
            ? launch
            : GameAudioScope(audio: audio, child: launch);
      },
      themeMode: mode,
      home: !loaded
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : data['setupComplete'] != true
          ? SetupPage(host: bridge, firstRun: true, onDone: finishSetup)
          : Home(
              data: data,
              write: write,
              distribution: distribution,
              updates: updates,
              chatmail: chatmail,
              openChats: _openChats,
              chatAlert: _chatAlertTarget,
              onTheme: (value) {
                write('theme', value.name);
                setState(() => mode = value);
              },
            ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({
    super.key,
    required this.data,
    required this.write,
    required this.onTheme,
    required this.distribution,
    required this.updates,
    required this.chatmail,
    this.openChats = 0,
    this.chatAlert,
  });
  final int openChats;
  final ChatAlertTarget? chatAlert;
  final GithubDistribution? distribution;
  final Chatmail? chatmail;
  final AppUpdates? updates;
  final Map<String, dynamic> data;
  final void Function(String, dynamic) write;
  final ValueChanged<ThemeMode> onTheme;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  late int tab = widget.openChats > 0 ? 0 : 1;

  @override
  void initState() {
    super.initState();
    _routeChatAlert();
  }

  @override
  void didUpdateWidget(Home oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openChats != oldWidget.openChats) {
      tab = 0;
      _routeChatAlert();
    }
  }

  void _routeChatAlert() {
    final alert = widget.chatAlert;
    final request = widget.openChats;
    if (alert == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.openChats == request) {
        unawaited(_openChatAlert(alert, request));
      }
    });
  }

  Future<void> _openChatAlert(ChatAlertTarget alert, int request) async {
    final chatmail = widget.chatmail;
    if (chatmail == null) return;
    try {
      if (!await chatmail.restore()) return;
      final target = await chatmail.notificationMessage(
        alert.chat,
        alert.message,
        forDelivery: false,
      );
      if (!mounted || widget.openChats != request || target == null) return;
      final match = target.message.encrypted
          ? MatchEvent.parse(target.message.text)
          : null;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => match == null
              ? FriendConversation(
                  chatmail: chatmail,
                  id: alert.chat,
                  initialName: target.name,
                  pickGameLink: _installedGameLink,
                  openGameLink: _openGameLink,
                  prepareGame: _prepareOnlineGame,
                )
              : OnlineMatchPage(
                  chatmail: chatmail,
                  chat: alert.chat,
                  id: match.id,
                  playOnOpen: match.kind == 'move',
                  prepareGame: _prepareOnlineGame,
                  friendName: target.name,
                  buildChatDock: (close) => FriendConversation.docked(
                    chatmail: chatmail,
                    id: alert.chat,
                    onClose: close,
                  ),
                ),
        ),
      );
    } catch (_) {
      // Chats stays available if an old alert can no longer be opened.
    }
  }

  bool catalog = false;
  bool loadingCatalog = false;
  bool downloadingGame = false;
  bool openingGameLink = false;
  String? catalogError;
  List<GameRelease> releases = [];
  Map<String, GameRelease> _readLibrary() {
    final stored = widget.data['installedGames'];
    final legacy = widget.data['dropFourRelease'];
    final values = stored is Map ? stored.values : [if (legacy is Map) legacy];
    final library = <String, GameRelease>{};
    for (final value in values) {
      try {
        final game = GameRelease.fromJson(
          Map<String, dynamic>.from(value as Map),
        );
        final file = widget.distribution?.gameFile(game);
        if (file != null &&
            file.existsSync() &&
            file.lengthSync() == game.asset.size) {
          library[game.id] = game;
        }
      } catch (_) {
        // Ignore incomplete or invalid library records.
      }
    }
    return library;
  }

  late final Map<String, GameRelease> installedGames = _readLibrary();

  void _saveLibrary() => widget.write('installedGames', {
    for (final game in installedGames.values) game.id: game.toJson(),
  });

  Future<void> browseGames() async {
    setState(() => catalog = true);
    await refreshCatalog();
  }

  Future<void> refreshCatalog() async {
    if (loadingCatalog) return;
    final distribution = widget.distribution;
    if (distribution == null) {
      setState(
        () => catalogError =
            'Game storage is unavailable. Try reopening the app.',
      );
      return;
    }
    setState(() {
      loadingCatalog = true;
      catalogError = null;
    });
    try {
      final games = await distribution.catalog();
      if (mounted) setState(() => releases = games);
    } catch (_) {
      if (mounted)
        setState(() => catalogError = 'Couldn’t load the GitHub catalog.');
    } finally {
      if (mounted) setState(() => loadingCatalog = false);
    }
  }

  Future<bool> installGame(GameRelease release) async {
    final distribution = widget.distribution;
    if (downloadingGame ||
        distribution == null ||
        release.build < (installedGames[release.id]?.build ?? 0))
      return false;
    setState(() => downloadingGame = true);
    try {
      await distribution.installGame(release);
      await bridge.invokeMethod<void>('checkLoveGame', release.playerReference);
      if (!mounted) return false;
      setState(() {
        installedGames[release.id] = release;
        _saveLibrary();
        catalog = false;
      });
      return true;
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t download a verified game. Try again.'),
          ),
        );
      return false;
    } finally {
      if (mounted) setState(() => downloadingGame = false);
    }
  }

  void _gameNotice(String message) {
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _installedGameLink([GameRelease? game]) async {
    final release = game ?? installedGames['drop-four'];
    final distribution = widget.distribution;
    if (release == null || distribution == null) {
      _gameNotice('Install Cats vs Dogs from Get Games before sharing it.');
      return null;
    }
    try {
      if (!await distribution.verifyGame(release)) {
        _gameNotice('Reinstall this game before sharing it.');
        return null;
      }
      return GameLink.fromRelease(release).toString();
    } catch (_) {
      _gameNotice('Couldn’t verify the game for sharing. Try again.');
      return null;
    }
  }

  Future<GameRelease?> _prepareOnlineGame(GameLink link) async {
    final distribution = widget.distribution;
    if (distribution == null) {
      _gameNotice('Game storage is unavailable. Try reopening the app.');
      return null;
    }
    try {
      final installed = installedGames[link.id];
      if (installed != null &&
          link.matches(installed) &&
          installed.modes.contains('online') &&
          await distribution.verifyGame(installed)) {
        return installed;
      }
      final releases = await distribution.catalog(includeArchive: true);
      final exact = releases.where(link.matches).firstOrNull;
      if (!mounted) return null;
      if (exact == null) {
        _gameNotice('This exact game version isn’t in the official catalog.');
        return null;
      }
      // The first Drop Four release ran online in the host. Its match rules
      // are unchanged, so the current cartridge can render legacy matches.
      final playable = exact.modes.contains('online')
          ? exact
          : releases
                .where(
                  (game) =>
                      game.id == exact.id && game.modes.contains('online'),
                )
                .firstOrNull;
      if (playable == null) {
        _gameNotice('An online version of this game isn’t available.');
        return null;
      }
      if (installed != null &&
          playable.build == installed.build &&
          playable.asset.sha == installed.asset.sha &&
          await distribution.verifyGame(installed))
        return installed;
      if (installed != null && playable.build < installed.build) {
        await distribution.installGame(playable);
        await bridge.invokeMethod<void>(
          'checkLoveGame',
          playable.playerReference,
        );
        return playable;
      }
      return await installGame(playable) ? playable : null;
    } catch (_) {
      _gameNotice('Couldn’t verify the game for this match.');
      return null;
    }
  }

  Future<void> _shareInstalledGame(GameRelease game) async {
    final link = await _installedGameLink(game);
    if (link == null || !mounted) return;
    try {
      await bridge.invokeMethod<void>('shareGameLink', {'invite': link});
    } on PlatformException {
      _gameNotice('Couldn’t open sharing. Try again.');
    }
  }

  Future<void> _removeGame(GameRelease game) async {
    final distribution = widget.distribution;
    if (distribution == null || downloadingGame) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Remove ${game.title}?'),
        content: const Text(
          'This deletes the downloaded game. Saved progress is kept on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || downloadingGame) return;
    setState(() => downloadingGame = true);
    try {
      await distribution.removeGame(game);
      if (!mounted) return;
      setState(() {
        installedGames.remove(game.id);
        _saveLibrary();
      });
    } catch (_) {
      _gameNotice('Couldn’t remove the game. Try again.');
    } finally {
      if (mounted) setState(() => downloadingGame = false);
    }
  }

  Future<void> _pasteGameLink() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _GameLinkDialog(),
    );
    if (!mounted || text == null) return;
    final link = GameLink.parse(text);
    if (link == null) {
      _gameNotice('Paste a game link shared from Zompado.');
      return;
    }
    await _openGameLink(link);
  }

  Future<void> _openGameLink(GameLink link) async {
    if (openingGameLink) return;
    final distribution = widget.distribution;
    if (distribution == null) {
      _gameNotice('Game storage is unavailable. Try reopening the app.');
      return;
    }
    openingGameLink = true;
    try {
      final game = (await distribution.catalog(includeArchive: true))
          .where(link.matches)
          .firstOrNull;
      if (!mounted) return;
      if (game == null) {
        _gameNotice('This exact game version isn’t available in Get Games.');
        return;
      }
      final installed = installedGames[game.id];
      if (installed != null && game.build < installed.build) {
        _gameNotice(
          'You already have a newer version. Open My Games to play it.',
        );
        return;
      }
      final alreadyInstalled = installed?.build == game.build;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(game.title),
          content: Text('Official Zompado game · Version ${game.version}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(alreadyInstalled ? 'Play' : 'Install'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      if (alreadyInstalled || await installGame(game)) {
        if (mounted) await selectMode(game);
      }
    } catch (_) {
      _gameNotice(
        'Couldn’t verify this game link. Check your connection and try again.',
      );
    } finally {
      openingGameLink = false;
    }
  }

  Future<void> selectMode(GameRelease game) async {
    var mode = 'solo';
    final chatmail = widget.chatmail;
    final online = game.modes.contains('online') && chatmail != null;
    if (game.modes.contains('local') || online) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('Single Player'),
                onTap: () => Navigator.pop(sheet, 'solo'),
              ),
              if (online)
                ListTile(
                  leading: const Icon(Icons.public),
                  title: const Text('Online Match'),
                  subtitle: const Text('Play against a friend online'),
                  onTap: () => Navigator.pop(sheet, 'matches'),
                ),
              if (game.modes.contains('local'))
                ListTile(
                  leading: const Icon(Icons.people_outline),
                  title: const Text('Pass & Play'),
                  subtitle: const Text('Two Player share same device'),
                  onTap: () => Navigator.pop(sheet, 'local'),
                ),
            ],
          ),
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'matches' && chatmail != null) {
        final openChats = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (page) => Scaffold(
              appBar: AppBar(title: const Text('Online matches')),
              body: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(page, false),
                      icon: const Icon(Icons.person_add_outlined),
                      label: const Text('Invite a friend'),
                    ),
                    OnlineMatches(
                      chatmail: chatmail,
                      prepareGame: _prepareOnlineGame,
                      onOpenChats: () => Navigator.pop(page, true),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        if (mounted && openChats == true) setState(() => tab = 0);
        if (mounted && openChats == false) await _inviteForGame(chatmail, game);
        return;
      }
      mode = choice;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            GamePlayPage.official(game: game, title: game.title, mode: mode),
      ),
    );
  }

  Future<void> _inviteForGame(Chatmail chatmail, GameRelease game) async {
    try {
      if (!await chatmail.restore()) {
        if (mounted) setState(() => tab = 0);
        return;
      }
      final contacts = await chatmail.contacts();
      if (!mounted) return;
      final contact = await showModalBottomSheet<ChatContact>(
        context: context,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Invite a friend to play')),
              if (contacts.isEmpty)
                const ListTile(title: Text('Add a contact in Chats first.')),
              for (final entry in contacts)
                ListTile(
                  title: Text(entry.name),
                  onTap: () => Navigator.pop(sheet, entry),
                ),
            ],
          ),
        ),
      );
      if (contact == null || !mounted) return;
      final chat = await chatmail.openContact(contact.id);
      final invite = MatchEvent.invite(GameLink.fromRelease(game));
      await chatmail.send(chat, invite.wire);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => OnlineMatchPage(
            chatmail: chatmail,
            chat: chat,
            id: invite.id,
            friendName: contact.name,
            prepareGame: _prepareOnlineGame,
            buildChatDock: (close) => FriendConversation.docked(
              chatmail: chatmail,
              id: chat,
              onClose: close,
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted)
        _gameNotice(
          'Couldn’t send an invitation. Check that this friend can receive encrypted messages.',
        );
    }
  }

  void settings() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => Preferences(
        data: widget.data,
        write: widget.write,
        onTheme: widget.onTheme,
        updates: widget.updates,
        chatmail: widget.chatmail,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isGames = tab == 1;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              ZompadoBrand.markAsset,
              width: 25,
              height: 25,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 10),
            Text(
              isGames ? 'Games' : 'Chats',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          if (isGames)
            IconButton(
              tooltip: 'Open game link',
              onPressed: _pasteGameLink,
              icon: const Icon(Icons.link_rounded),
            ),
          if (isGames)
            IconButton(
              tooltip: 'Import a Game',
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => LoveImports(
                    host: bridge,
                    read: () => widget.data['loveImports'] as List? ?? const [],
                    save: (files) => widget.write('loveImports', files),
                  ),
                ),
              ),
              icon: const Icon(Icons.file_open_outlined),
            ),
          IconButton(
            tooltip: 'Settings',
            onPressed: settings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (widget.updates?.available case final update?)
            MaterialBanner(
              content: Text('Zompado ${update.version} is available.'),
              actions: [
                TextButton(
                  onPressed: settings,
                  child: const Text('View update'),
                ),
              ],
            ),
          Expanded(
            child: isGames
                ? games()
                : widget.chatmail == null
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        'Chatmail is unavailable on this device or build.',
                      ),
                    ),
                  )
                : FriendsPane(
                    chatmail: widget.chatmail!,
                    pickGameLink: _installedGameLink,
                    openGameLink: _openGameLink,
                    prepareGame: _prepareOnlineGame,
                    share: (invite) => bridge.invokeMethod<void>(
                      'shareFriendInvite',
                      {'invite': invite},
                    ),
                  ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_esports_outlined),
            selectedIcon: Icon(Icons.sports_esports),
            label: 'Games',
          ),
        ],
      ),
    );
  }

  Widget games() {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('My Games')),
              ButtonSegment(value: true, label: Text('Get Games')),
            ],
            selected: {catalog},
            showSelectedIcon: false,
            onSelectionChanged: (values) {
              if (values.first) {
                browseGames();
              } else {
                setState(() => catalog = false);
              }
            },
          ),
        ),
        const SizedBox(height: 20),
        if (!catalog)
          if (widget.chatmail case final Chatmail chatmail)
            OnlineMatches(chatmail: chatmail, prepareGame: _prepareOnlineGame),
        Row(
          children: [
            Expanded(
              child: Text(
                catalog ? 'Official game catalog' : 'Your library',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (catalog)
              IconButton(
                tooltip: 'Refresh catalog',
                onPressed: loadingCatalog ? null : refreshCatalog,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          catalog
              ? 'Games released independently from the app.'
              : 'Installed games are ready to play.',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (catalog) ...[
          if (loadingCatalog || downloadingGame)
            const LinearProgressIndicator(),
          if (catalogError case final error?) ...[
            ListTile(
              title: Text(error),
              trailing: TextButton(
                onPressed: refreshCatalog,
                child: const Text('Retry'),
              ),
            ),
          ],
          for (final game in releases) ...[
            gameCard(
              game.title,
              'Version ${game.version} · .zomp · ${game.asset.size < 1024 ? '${game.asset.size} B' : '${(game.asset.size / 1024).toStringAsFixed(1)} KB'}',
              (installedGames[game.id]?.build ?? 0) >= game.build
                  ? 'Play'
                  : installedGames.containsKey(game.id)
                  ? 'Update'
                  : 'Install',
              downloadingGame
                  ? null
                  : () {
                      final installed = installedGames[game.id];
                      if (installed != null && installed.build >= game.build) {
                        selectMode(installed);
                      } else {
                        installGame(game);
                      }
                    },
              game: game,
            ),
            const SizedBox(height: 12),
          ],
          if (!loadingCatalog && catalogError == null && releases.isEmpty)
            const Text('No games in the catalog yet.'),
        ] else if (installedGames.isNotEmpty)
          for (final game in installedGames.values) ...[
            gameCard(
              game.title,
              'Version ${game.version} · .zomp',
              'Play',
              downloadingGame ? null : () => selectMode(game),
              game: game,
              share: () => _shareInstalledGame(game),
              remove: downloadingGame ? null : () => _removeGame(game),
            ),
            const SizedBox(height: 12),
          ]
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.sports_esports_outlined,
                    color: colors.primary,
                    size: 36,
                  ),
                  const SizedBox(height: 12),
                  const Text('Your library is empty'),
                  const SizedBox(height: 4),
                  const Text('Open Get Games to download a game.'),
                  const SizedBox(height: 14),
                  OutlinedButton(
                    onPressed: browseGames,
                    child: const Text('Browse games'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget gameCard(
    String title,
    String description,
    String button,
    VoidCallback? action, {
    required GameRelease game,
    VoidCallback? share,
    VoidCallback? remove,
  }) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (game.id == 'drop-four')
          SizedBox(
            height: 146,
            child: game.build >= 6
                ? const CatsVsDogsCover()
                : const GameCover(),
          ),
        Padding(
          padding: const EdgeInsets.all(17),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(description),
                  ],
                ),
              ),
              if (share != null || remove != null)
                PopupMenuButton<String>(
                  tooltip: 'Game options',
                  onSelected: (choice) =>
                      (choice == 'remove' ? remove : share)?.call(),
                  itemBuilder: (_) => [
                    if (share != null)
                      const PopupMenuItem(value: 'share', child: Text('Share')),
                    if (remove != null)
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove'),
                      ),
                  ],
                ),
              FilledButton(onPressed: action, child: Text(button)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _GameLinkDialog extends StatefulWidget {
  const _GameLinkDialog();

  @override
  State<_GameLinkDialog> createState() => _GameLinkDialogState();
}

class _GameLinkDialogState extends State<_GameLinkDialog> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Open game link'),
    content: TextField(
      controller: _input,
      decoration: const InputDecoration(labelText: 'Zompado game link'),
      maxLength: 512,
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () async {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          final text = data?.text?.trim();
          if (mounted && text != null && text.length <= 512) _input.text = text;
        },
        child: const Text('Paste'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _input.text),
        child: const Text('Open'),
      ),
    ],
  );
}

class CatsVsDogsCover extends StatelessWidget {
  const CatsVsDogsCover({super.key});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0xff502039), Color(0xff14172b), Color(0xff1f3f68)],
      ),
    ),
    child: Image.asset(
      'assets/games/cats-vs-dogs.webp',
      fit: BoxFit.contain,
      excludeFromSemantics: true,
    ),
  );
}

class GameCover extends StatelessWidget {
  const GameCover({super.key});
  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [ZompadoBrand.darkPanel, Color(0xff1c4c63)],
      ),
    ),
    child: Center(
      child: Transform.rotate(
        angle: -0.13,
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: ZompadoBrand.ink,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ZompadoBrand.wordmarkBlue, width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in const [
                [0, 0, 0, 2],
                [0, 1, 2, 2],
                [1, 2, 1, 1],
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final piece in row)
                      Padding(
                        padding: const EdgeInsets.all(3),
                        child: Piece(side: piece, size: 23),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class Piece extends StatelessWidget {
  const Piece({
    super.key,
    required this.side,
    required this.size,
    this.preview = false,
  });
  final int side;
  final double size;
  final bool preview;
  @override
  Widget build(BuildContext context) {
    final color = switch (side) {
      1 => gold,
      2 => lilac,
      _ => ZompadoBrand.ink,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: preview ? 0.55 : 1),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: side == 0 ? .10 : .35),
        ),
        gradient: side != 0 && !preview
            ? RadialGradient(
                center: const Alignment(-.4, -.5),
                colors: [
                  Color.lerp(color, Colors.white, .36)!,
                  color,
                  Color.lerp(color, Colors.black, .21)!,
                ],
              )
            : null,
      ),
    );
  }
}

class Preferences extends StatefulWidget {
  const Preferences({
    super.key,
    required this.data,
    required this.write,
    required this.onTheme,
    required this.updates,
    required this.chatmail,
  });
  final AppUpdates? updates;
  final Chatmail? chatmail;
  final Map<String, dynamic> data;
  final void Function(String, dynamic) write;
  final ValueChanged<ThemeMode> onTheme;
  @override
  State<Preferences> createState() => _PreferencesState();
}

class _PreferencesState extends State<Preferences> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        ListTile(
          leading: const Icon(Icons.tune_rounded),
          title: const Text('Setup'),
          subtitle: const Text('Review permissions and update options'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (route) => SetupPage(
                host: bridge,
                onDone: () => Navigator.of(route).pop(),
              ),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.help_outline_rounded),
          title: const Text('Help'),
          subtitle: const Text(
            'Find answers about games, friends, and updates',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const HelpPage())),
        ),
        if (widget.chatmail case final chatmail?)
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: const Text('My profile'),
            subtitle: const Text('Name, photo, and bio'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => ProfilePage(chatmail: chatmail),
              ),
            ),
          ),
        SwitchListTile(
          secondary: const Icon(Icons.palette_outlined),
          title: const Text('Appearance'),
          subtitle: Text(widget.data['theme'] == 'light' ? 'Light' : 'Dark'),
          value: widget.data['theme'] != 'light',
          onChanged: (dark) {
            widget.onTheme(dark ? ThemeMode.dark : ThemeMode.light);
            setState(() {});
          },
        ),
        ListTile(
          leading: const Icon(Icons.volume_up_outlined),
          title: const Text('Game audio'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => GameAudioButton.show(context),
        ),
        if (widget.updates case final updates?)
          ListenableBuilder(
            listenable: updates,
            builder: (context, _) => Column(
              children: [
                SwitchListTile(
                  title: const Text('Automatic update checks'),
                  subtitle: const Text(
                    'Check GitHub daily and when you open the app.',
                  ),
                  value: updates.automatic,
                  onChanged: updates.setAutomatic,
                ),
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: const Text('Check for updates'),
                  subtitle: updates.status == null
                      ? null
                      : Text(updates.status!),
                  enabled: !updates.checking && !updates.downloading,
                  onTap: () => updates.check(),
                ),
                if (updates.available case final release?)
                  ListTile(
                    title: Text('Version ${release.version}'),
                    trailing: FilledButton(
                      onPressed: updates.downloading ? null : updates.install,
                      child: Text(
                        updates.downloading ? 'Downloading…' : 'Update',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('About this build'),
          subtitle: const Text('Android prototype · $installedVersion'),
        ),
      ],
    ),
  );
}
