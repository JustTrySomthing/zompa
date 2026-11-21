import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart';

import 'brand.dart';
import 'app_updates.dart';
import 'app_log.dart';
import 'github_distribution.dart';
import 'game_link.dart';
import 'chatmail.dart';
import 'chat_chrome.dart';
import 'message_bubble.dart';
import 'communication_settings.dart';
import 'contacts_page.dart';
import 'compression_page.dart';
import 'saved_messages.dart';
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
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    recordAppEvent('Flutter error ${details.exception.runtimeType}');
    previousFlutterError?.call(details);
  };
  final dispatcher = PlatformDispatcher.instance;
  final previousPlatformError = dispatcher.onError;
  dispatcher.onError = (error, stack) {
    recordAppEvent('Uncaught Dart error ${error.runtimeType}');
    return previousPlatformError?.call(error, stack) ?? false;
  };
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
  final _home = GlobalKey<_HomeState>();
  final _notifications = ChatNotificationSettings(bridge);
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
    unawaited(_notifications.load());
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
      var label = message.viewType == 'Call'
          ? 'Zompado call activity'
          : 'New message';
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
        'kind': event == null
            ? (message.viewType == 'Call' ? 'calls' : 'messages')
            : 'invites',
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
    _notifications.dispose();
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
        return ChatChrome(
          notifications: _notifications,
          messageTextSize: messageTextSizeFrom(data['messageTextSize']),
          openSettings: data['setupComplete'] != true
              ? null
              : (route) => _home.currentState?.openSettings(route),
          openContacts: chatmail == null || data['setupComplete'] != true
              ? null
              : (route) => _home.currentState?.openContacts(route),
          openSaved: chatmail == null || data['setupComplete'] != true
              ? null
              : (route) => _home.currentState?.openSaved(route),
          child: audio == null
              ? launch
              : GameAudioScope(audio: audio, child: launch),
        );
      },
      themeMode: mode,
      home: !loaded
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : data['setupComplete'] != true
          ? SetupPage(host: bridge, firstRun: true, onDone: finishSetup)
          : Home(
              key: _home,
              data: data,
              write: (key, value) {
                write(key, value);
                if (key == 'messageTextSize') setState(() {});
              },
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
                  installedGames: _installedGameChoices,
                  verifiedGameLink: _installedGameLink,
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

  List<GameRelease> _installedGameChoices() => installedGames.values.toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  Future<String?> _installedGameLink(GameRelease release) async {
    final distribution = widget.distribution;
    if (distribution == null) {
      _gameNotice('Game storage is unavailable. Try reopening the app.');
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
    final online = MatchEvent.supportsGame(game) && chatmail != null;
    if (game.modes.contains('local') || online) {
      final hasActiveGame = online
          ? chatmail.activeMatches().then(
              (entries) => entries.any(
                (entry) => entry.match.invite.game?.id == game.id,
              ),
              onError: (Object _, StackTrace _) => true,
            )
          : null;
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (sheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 8),
            child: FutureBuilder<bool>(
              future: hasActiveGame,
              builder: (context, snapshot) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (snapshot.data == true)
                    ListTile(
                      leading: const Icon(Icons.play_circle_outline),
                      title: const Text('Resume an Active Game'),
                      onTap: () => Navigator.pop(sheet, 'resume'),
                    ),
                  if (game.modes.contains('solo'))
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('Single Player'),
                      onTap: () => Navigator.pop(sheet, 'solo'),
                    ),
                  if (online)
                    ListTile(
                      leading: const Icon(Icons.public),
                      title: const Text('New Online Match'),
                      subtitle: const Text('Invite a friend to play'),
                      onTap: () => Navigator.pop(sheet, 'online'),
                    ),
                  if (game.modes.contains('local'))
                    ListTile(
                      leading: const Icon(Icons.people_outline),
                      title: const Text('Pass & Play'),
                      subtitle: const Text('Two players on one device'),
                      onTap: () => Navigator.pop(sheet, 'local'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'resume' && chatmail != null) {
        await showActiveGames(
          context,
          chatmail: chatmail,
          prepareGame: _prepareOnlineGame,
          game: game,
        );
        return;
      }
      if (choice == 'online' && chatmail != null) {
        await _inviteForGame(chatmail, game);
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
      final moved = await chatmail.sendMatchOpening(chat, invite);
      if (!mounted) return;
      if (moved != null) _gameNotice(matchMovedNotice(moved));
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

  Future<void> _conversation(BuildContext route, int id, String name) =>
      Navigator.of(route).push<void>(
        MaterialPageRoute(
          builder: (_) => FriendConversation(
            chatmail: widget.chatmail!,
            id: id,
            initialName: name,
            installedGames: _installedGameChoices,
            verifiedGameLink: _installedGameLink,
            openGameLink: _openGameLink,
            prepareGame: _prepareOnlineGame,
          ),
        ),
      );

  Future<void> openContacts(BuildContext route) async {
    final chatmail = widget.chatmail;
    if (chatmail == null) return;
    try {
      if (!await chatmail.restore()) {
        if (route.mounted)
          ScaffoldMessenger.of(route).showSnackBar(
            const SnackBar(
              content: Text('Create your chat profile in Chats first.'),
            ),
          );
        return;
      }
      if (!mounted || !route.mounted) return;
      final pins =
          (widget.data['pinnedContacts'] as List?)?.whereType<int>().toSet() ??
          <int>{};
      await Navigator.of(route).push<void>(
        MaterialPageRoute(
          builder: (contacts) {
            final invites = ContactInvites(
              contacts,
              chatmail,
              (chat, name) => _conversation(contacts, chat, name),
              (invite) => bridge.invokeMethod<void>('shareFriendInvite', {
                'invite': invite,
              }),
            );
            return ContactsPage(
              chatmail: chatmail,
              invite: invites.create,
              acceptInvite: invites.accept,
              open: (contact) async {
                final id = await chatmail.openContact(contact.id);
                if (contacts.mounted)
                  await _conversation(contacts, id, contact.name);
              },
              pins: pins,
              savePins: (values) =>
                  widget.write('pinnedContacts', values.toList()),
            );
          },
        ),
      );
    } catch (_) {
      if (route.mounted)
        ScaffoldMessenger.of(route).showSnackBar(
          const SnackBar(content: Text('Couldn’t open Contacts.')),
        );
    }
  }

  void openSaved(BuildContext route) {
    final chatmail = widget.chatmail;
    if (chatmail == null) return;
    Navigator.of(route).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            SavedMessagesPage(chatmail: chatmail, openGame: _openGameLink),
      ),
    );
  }

  void openSettings(BuildContext context) => Navigator.of(context).push<void>(
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
    final colors = Theme.of(context).colorScheme;
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
            Flexible(
              child: Text(
                isGames ? 'Games' : 'Chats',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        actions: chatActions(context),
      ),
      body: Column(
        children: [
          if (widget.updates?.available case final update?)
            MaterialBanner(
              content: Text('Zompado ${update.version} is available.'),
              actions: [
                TextButton(
                  onPressed: () => openSettings(context),
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
                    installedGames: _installedGameChoices,
                    verifiedGameLink: _installedGameLink,
                    openGameLink: _openGameLink,
                    prepareGame: _prepareOnlineGame,
                  ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          expandedInsets: EdgeInsets.zero,
          segments: [
            ButtonSegment(
              value: 0,
              label: const Text('Chats'),
              icon: Icon(isGames ? Icons.chat_outlined : Icons.chat, size: 26),
            ),
            ButtonSegment(
              value: 1,
              label: const Text('Games'),
              icon: Icon(
                isGames ? Icons.sports_esports : Icons.sports_esports_outlined,
                size: 26,
              ),
            ),
          ],
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size(0, 52)),
            textStyle: WidgetStatePropertyAll(
              Theme.of(context).textTheme.titleMedium,
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? colors.secondaryContainer
                  : colors.surface,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? colors.onSecondaryContainer
                  : colors.onSurfaceVariant,
            ),
          ),
          selected: {tab},
          onSelectionChanged: (value) => setState(() => tab = value.single),
        ),
      ),
    );
  }

  Future<void> _openGameOptions() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('Import or Open Game Link'),
        children: [
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('Import a Game'),
            onTap: () => Navigator.pop(dialog, 'import'),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Open Game Link'),
            onTap: () => Navigator.pop(dialog, 'link'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'link') {
      await _pasteGameLink();
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => LoveImports(
            host: bridge,
            read: () => widget.data['loveImports'] as List? ?? const [],
            save: (files) => widget.write('loveImports', files),
          ),
        ),
      );
    }
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
        Align(
          child: TextButton(
            style: TextButton.styleFrom(foregroundColor: colors.onSurfaceVariant),
            onPressed: _openGameOptions,
            child: const Text('Import or Open Game Link'),
          ),
        ),
        const SizedBox(height: 12),
        if (!catalog && widget.chatmail != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
                backgroundColor: colors.surfaceContainer,
                foregroundColor: colors.onSurfaceVariant,
              ),
              onPressed: () => showActiveGames(
                context,
                chatmail: widget.chatmail!,
                prepareGame: _prepareOnlineGame,
              ),
              icon: const Icon(Icons.sports_esports_outlined),
              label: const Text('Active Games'),
            ),
          ),
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
                  ? null
                  : installedGames.containsKey(game.id)
                  ? 'Update'
                  : 'Install',
              downloadingGame ? null : () => installGame(game),
              installed: installedGames.containsKey(game.id),
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
    String? button,
    VoidCallback? action, {
    required GameRelease game,
    bool installed = false,
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
                    if (installed)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle_outline, size: 16),
                            const SizedBox(width: 5),
                            Text(
                              'Installed',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ],
                        ),
                      ),
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
              if ((share != null || remove != null) && button != null)
                const SizedBox(width: 8),
              if (button != null)
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
  Widget build(BuildContext context) {
    final chatmail = widget.chatmail;
    final chrome = ChatChrome.of(context);
    void open(Widget page) => Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => page));

    final buttons = <Widget>[
      if (chatmail != null)
        _SettingsButton(
          'Profile',
          onPressed: () => open(ProfilePage(chatmail: chatmail)),
        ),
      _SettingsButton(
        'Appearance',
        onPressed: () => open(
          _AppearancePage(
            data: widget.data,
            write: widget.write,
            onTheme: widget.onTheme,
          ),
        ),
      ),
      if (chrome != null)
        _SettingsButton(
          'Notifications',
          onPressed: () =>
              open(NotificationsPage(settings: chrome.notifications)),
        ),
      _SettingsButton(
        'Quiet Hours',
        onPressed: () => open(const QuietHoursPage()),
      ),
      _SettingsButton(
        'Game audio',
        onPressed: () => GameAudioButton.show(context),
      ),
      if (chatmail != null) ...[
        _SettingsButton(
          'Compression',
          onPressed: () => open(CompressionPage(chatmail: chatmail)),
        ),
        _SettingsButton(
          'Backup',
          onPressed: () => open(BackupPage(chatmail: chatmail)),
        ),
        _SettingsButton(
          'Connections',
          onPressed: () => open(ConnectionsPage(chatmail: chatmail)),
        ),
      ],
      _SettingsButton(
        'Setup',
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (route) => SetupPage(
              host: bridge,
              onDone: () => Navigator.of(route).pop(),
            ),
          ),
        ),
      ),
      _SettingsButton('Help', onPressed: () => open(const HelpPage())),
      _SettingsButton('App Log', onPressed: () => open(const AppLogPage())),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: chatActions(context, settings: false),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
          children: [
            LayoutBuilder(
              builder: (context, box) {
                final scaledLabel = MediaQuery.textScalerOf(context).scale(16);
                final columns =
                    box.maxWidth >= 240 &&
                        (box.maxWidth - 14) / 2 >= scaledLabel * 5
                    ? 2
                    : 1;
                final items = [
                  ...buttons,
                  if (columns == 2 && buttons.length.isEven) const SizedBox(),
                  _SettingsButton(
                    'About',
                    onPressed: () => open(const _AboutPage()),
                  ),
                ];
                return Column(
                  children: [
                    for (var i = 0; i < items.length; i += columns)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: items[i]),
                              if (columns == 2) ...[
                                const SizedBox(width: 14),
                                Expanded(
                                  child: i + 1 < items.length
                                      ? items[i + 1]
                                      : const SizedBox(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (widget.updates case final updates?)
              ListenableBuilder(
                listenable: updates,
                builder: (context, _) => _settingsCard(
                  context,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.system_update_alt),
                        title: const Text('App updates'),
                        subtitle: Text('Installed version $installedVersion'),
                      ),
                      SwitchListTile(
                        title: const Text('Check automatically'),
                        value: updates.automatic,
                        onChanged: updates.setAutomatic,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (updates.status case final status?)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(status),
                                ),
                              ),
                            if (updates.available case final release?)
                              FilledButton.icon(
                                onPressed:
                                    updates.checking || updates.downloading
                                    ? null
                                    : updates.install,
                                icon: const Icon(Icons.download),
                                label: Text(
                                  updates.downloading
                                      ? 'Downloading…'
                                      : 'Install ${release.version}',
                                ),
                              ),
                            OutlinedButton.icon(
                              onPressed: updates.checking || updates.downloading
                                  ? null
                                  : updates.check,
                              icon: const Icon(Icons.refresh),
                              label: Text(
                                updates.checking
                                    ? 'Checking…'
                                    : 'Check for updates',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              _settingsCard(
                context,
                ListTile(
                  leading: const Icon(Icons.system_update_alt),
                  title: const Text('App updates'),
                  subtitle: Text('Installed version $installedVersion'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton(this.label, {required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurface,
        backgroundColor:
            theme.cardTheme.color ?? theme.colorScheme.surfaceContainer,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        minimumSize: const Size(0, 58),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      ),
      onPressed: onPressed,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium,
      ),
    );
  }
}

class _AboutPage extends StatelessWidget {
  const _AboutPage();

  Future<void> _openGitHub(BuildContext context) async {
    try {
      final opened = await bridge.invokeMethod<bool>('openPreviewExternal', {
        'url': 'https://github.com/$githubOwner/$appRepository',
      });
      if (opened == true) return;
    } on PlatformException {
      // A browser may be unavailable on this device.
    } on MissingPluginException {
      // The Android host provides external browsing.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t open GitHub.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('About')),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Zompado', style: Theme.of(context).textTheme.headlineMedium),
          const Text('Version $installedVersion'),
          const SizedBox(height: 16),
          const Text('Play, share games, and chat with friends.'),
          const SizedBox(height: 16),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: () => _openGitHub(context),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Zompado on GitHub'),
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _settingsCard(BuildContext context, Widget child) {
  final colors = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: child,
    ),
  );
}

class _AppearancePage extends StatefulWidget {
  const _AppearancePage({
    required this.data,
    required this.write,
    required this.onTheme,
  });

  final Map<String, dynamic> data;
  final void Function(String, dynamic) write;
  final ValueChanged<ThemeMode> onTheme;

  @override
  State<_AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<_AppearancePage> {
  late double _size = messageTextSizeFrom(widget.data['messageTextSize']);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Appearance'),
      actions: chatActions(context),
    ),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
        children: [
          _settingsCard(
            context,
            SwitchListTile(
              secondary: const Icon(Icons.dark_mode_outlined),
              title: const Text('Dark theme'),
              value: widget.data['theme'] != 'light',
              onChanged: (dark) {
                widget.onTheme(dark ? ThemeMode.dark : ThemeMode.light);
                setState(() {});
              },
            ),
          ),
          _settingsCard(
            context,
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Message text size',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Slider(
                    value: _size,
                    min: minMessageTextSize,
                    max: maxMessageTextSize,
                    divisions: (maxMessageTextSize - minMessageTextSize)
                        .toInt(),
                    label: _size.round().toString(),
                    semanticFormatterCallback: (size) => '${size.round()}',
                    onChanged: (size) => setState(() => _size = size),
                    onChangeEnd: (size) =>
                        widget.write('messageTextSize', size),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: MessageBubble(
                      outgoing: true,
                      builder: (_) =>
                          MessageBody('See you in the game!', size: _size),
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
