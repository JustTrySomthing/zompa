import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'board.dart';
import 'app_updates.dart';
import 'github_distribution.dart';

const gold = Color(0xffffdc71);
const lilac = Color(0xffc9b7ff);
const ink = Color(0xff14171f);
const panel = Color(0xff252a36);
const bridge = MethodChannel('io.tablecircle.host');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TableCircle());
}

class TableCircle extends StatefulWidget {
  const TableCircle({super.key});
  @override
  State<TableCircle> createState() => _TableCircleState();
}

class _TableCircleState extends State<TableCircle> with WidgetsBindingObserver {
  ThemeMode mode = ThemeMode.dark;
  File? storage;
  Map<String, dynamic> data = {};
  Future<void> pendingWrite = Future.value();
  GithubDistribution? distribution;
  AppUpdates? updates;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  Future<void> load() async {
    try {
      final path = await bridge.invokeMethod<String>('dataPath');
      if (path != null) {
        storage = File('$path/profile.json');
        if (await storage!.exists()) {
          data = Map<String, dynamic>.from(
            jsonDecode(await storage!.readAsString()),
          );
          mode = ThemeMode.values.byName(data['theme'] as String? ?? 'dark');
        }
      }
    } catch (e) {
      debugPrint('Could not load local preferences: $e');
    }
    if (!mounted) return;
    final file = storage;
    if (file != null) {
      distribution = GithubDistribution(file.parent);
      updates = AppUpdates(distribution!, bridge, data, write)
        ..addListener(updateChanged);
      updates!.syncSchedule();
      updates!.checkIfDue();
    }
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
    ThemeData theme(Brightness brightness) {
      final dark = brightness == Brightness.dark;
      final scheme =
          ColorScheme.fromSeed(
            seedColor: const Color(0xff7252b5),
            brightness: brightness,
          ).copyWith(
            primary: dark ? gold : const Color(0xff5f4300),
            secondary: dark ? lilac : const Color(0xff5d3f91),
            surface: dark ? ink : const Color(0xfffaf7ff),
          );
      return ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        appBarTheme: AppBarTheme(
          backgroundColor: scheme.surface,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          color: dark ? panel : const Color(0xffeee9f6),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      );
    }

    return MaterialApp(
      title: 'Table Circle',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: mode,
      home: Home(
        data: data,
        write: write,
        distribution: distribution,
        updates: updates,
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
  });
  final GithubDistribution? distribution;
  final AppUpdates? updates;
  final Map<String, dynamic> data;
  final void Function(String, dynamic) write;
  final ValueChanged<ThemeMode> onTheme;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 1;
  bool catalog = false;
  bool loadingCatalog = false;
  bool downloadingGame = false;
  String? catalogError;
  List<GameRelease> releases = [];
  int get installedBuild => widget.data['dropFourBuild'] as int? ?? 0;

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

  Future<void> installGame(GameRelease release) async {
    final distribution = widget.distribution;
    if (downloadingGame || !release.playable || distribution == null) return;
    setState(() => downloadingGame = true);
    try {
      await distribution.installGame(release);
      if (!mounted) return;
      widget.write('dropFourBuild', release.build);
      widget.write('dropFourVersion', release.version);
      setState(() => catalog = false);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t download a verified game. Try again.'),
          ),
        );
    } finally {
      if (mounted) setState(() => downloadingGame = false);
    }
  }

  List<String> get messages =>
      (widget.data['previewMessages'] as List?)?.cast<String>() ?? [];
  bool get installed => installedBuild > 0 || widget.data['installed'] == true;

  void openMatch({required bool solo}) {
    final saveKey = solo ? 'soloBoard' : 'localBoard';
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MatchPage(
          solo: solo,
          saved: widget.data[saveKey] as List?,
          messages: messages,
          save: (value) => widget.write(saveKey, value),
          saveMessages: (value) => widget.write('previewMessages', value),
          sound: widget.data['effects'] != false,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  void selectMode() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    'Drop Four',
                    style: Theme.of(sheet).textTheme.headlineSmall,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('Play solo'),
                  subtitle: Text(
                    widget.data['soloBoard'] == null
                        ? 'Play against the computer, offline'
                        : 'Resume your offline game',
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    openMatch(solo: true);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.people_outline),
                  title: const Text('Pass and play'),
                  subtitle: const Text(
                    'Take turns on this phone. Includes a local chat preview.',
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    openMatch(solo: false);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void settings() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => Preferences(
        data: widget.data,
        write: widget.write,
        onTheme: widget.onTheme,
        updates: widget.updates,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isGames = tab == 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isGames ? 'Games' : 'Chats',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (isGames)
            IconButton(
              tooltip: 'Import game',
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Import game'),
                    content: const Text(
                      'Game import needs the isolated LÖVE player. This prototype includes one built-in game.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                );
              },
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
              content: Text('Table Circle ${update.version} is available.'),
              actions: [
                TextButton(
                  onPressed: settings,
                  child: const Text('View update'),
                ),
              ],
            ),
          Expanded(child: isGames ? games() : chats()),
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
        Row(
          children: [
            Expanded(
              child: Text(
                catalog ? 'Official game catalog' : 'Your library',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
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
              'Version ${game.version} · ${game.asset.size < 1024 ? '${game.asset.size} B' : '${(game.asset.size / 1024).toStringAsFixed(1)} KB'}',
              game.playable
                  ? game.build <= installedBuild
                        ? 'Play'
                        : installedBuild > 0
                        ? 'Update'
                        : 'Install'
                  : 'Player required',
              !game.playable || downloadingGame
                  ? null
                  : game.build <= installedBuild
                  ? selectMode
                  : () => installGame(game),
            ),
            const SizedBox(height: 12),
          ],
          if (!loadingCatalog && catalogError == null && releases.isEmpty)
            const Text('No games in the catalog yet.'),
        ] else if (installed)
          gameCard('Drop Four', 'Solo · Pass and play', 'Play', selectMode)
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
                  const Text('Open Get Games to add Drop Four.'),
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
    VoidCallback? action,
  ) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 146, child: GameCover()),
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
              FilledButton(onPressed: action, child: Text(button)),
            ],
          ),
        ),
      ],
    ),
  );

  Widget chats() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          leading: const CircleAvatar(
            backgroundColor: lilac,
            foregroundColor: Colors.black,
            child: Icon(Icons.forum_outlined),
          ),
          title: const Text(
            'Match chat preview',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            messages.isEmpty ? 'Messages stay on this phone' : messages.last,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () =>
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Match chat preview')),
                    body: SafeArea(
                      child: ChatPanel(
                        messages: messages,
                        onChange: (value) =>
                            widget.write('previewMessages', value),
                      ),
                    ),
                  ),
                ),
              ).then((_) {
                if (mounted) setState(() {});
              }),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        'This preview uses local chat. Chatmail accounts, friend invites, and voice calling are not connected in this build.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ],
  );
}

class GameCover extends StatelessWidget {
  const GameCover({super.key});
  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(colors: [Color(0xff243c73), Color(0xff532e73)]),
    ),
    child: Center(
      child: Transform.rotate(
        angle: -0.13,
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: const Color(0xff182447),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xff607bd1), width: 2),
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
      _ => const Color(0xff121a35),
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

class MatchPage extends StatefulWidget {
  const MatchPage({
    super.key,
    required this.solo,
    required this.saved,
    required this.messages,
    required this.save,
    required this.saveMessages,
    required this.sound,
  });
  final bool solo;
  final List? saved;
  final List<String> messages;
  final ValueChanged<List<int>> save;
  final ValueChanged<List<String>> saveMessages;
  final bool sound;
  @override
  State<MatchPage> createState() => _MatchPageState();
}

class _MatchPageState extends State<MatchPage> {
  late Board board = widget.saved == null ? Board() : Board.from(widget.saved!);
  int? selected;
  bool chat = false;
  List<String> get messages => widget.messages;
  bool get finished => board.winner != 0 || board.full;

  @override
  void initState() {
    super.initState();
    if (widget.solo && board.turn == 2 && !finished) {
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (mounted && !finished && board.turn == 2)
          commit(board.computerMove());
      });
    }
  }

  void commit(int column) {
    if (!board.drop(column)) return;
    if (widget.sound) SystemSound.play(SystemSoundType.click);
    setState(() => selected = null);
    widget.save(List.of(board.cells));
    if (widget.solo && board.turn == 2 && !finished) {
      Future<void>.delayed(const Duration(milliseconds: 330), () {
        if (mounted && !finished && board.turn == 2)
          commit(board.computerMove());
      });
    }
  }

  Widget dock() => ChatPanel(
    messages: messages,
    onClose: toggleChat,
    onChange: (value) {
      messages
        ..clear()
        ..addAll(value);
      widget.saveMessages(List.of(value));
    },
  );

  void toggleChat() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => chat = !chat);
  }

  @override
  Widget build(BuildContext context) {
    final winner = board.winner;
    final title = winner != 0
        ? (widget.solo
              ? (winner == 1 ? 'You win!' : 'Computer wins')
              : 'Player $winner wins!')
        : board.full
        ? 'Draw'
        : widget.solo
        ? (board.turn == 1 ? 'Your turn' : 'Computer is moving…')
        : 'Player ${board.turn}’s turn';
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final canPlay = !finished && (!widget.solo || board.turn == 1);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Drop Four',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (!widget.solo)
            IconButton(
              tooltip: chat ? 'Close match chat' : 'Open match chat',
              onPressed: toggleChat,
              icon: Icon(chat ? Icons.chat_bubble : Icons.chat_bubble_outline),
            ),
          IconButton(
            tooltip: 'Restart game',
            icon: const Icon(Icons.restart_alt),
            onPressed: () async {
              final reset = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Restart this game?'),
                  content: const Text('The current board will be cleared.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Restart'),
                    ),
                  ],
                ),
              );
              if (mounted && reset == true) {
                setState(() {
                  board = Board();
                  selected = null;
                });
                widget.save(board.cells.toList());
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, page) {
            final dockHeight = !chat
                ? 0.0
                : keyboard
                ? page.maxHeight
                : (page.maxHeight * .46).clamp(0.0, 205.0);
            return Column(
              children: [
                SizedBox(
                  height: page.maxHeight - dockHeight,
                  child: LayoutBuilder(
                    builder: (context, bounds) {
                      return Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 10,
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: bounds.maxHeight > 480 ? 460 : 340,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Piece(
                                      side: winner == 0 ? board.turn : winner,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xff294880),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: const Color(0xff608bde),
                                      width: 2,
                                    ),
                                  ),
                                  child: AspectRatio(
                                    aspectRatio: 7 / 6,
                                    child: Row(
                                      children: List.generate(7, (column) {
                                        final previewSlot = selected == column
                                            ? board.landing(column)
                                            : -1;
                                        return Expanded(
                                          child: Semantics(
                                            button: true,
                                            label: 'Column ${column + 1}',
                                            selected: selected == column,
                                            enabled:
                                                canPlay &&
                                                board.landing(column) >= 0,
                                            child: InkWell(
                                              onTap:
                                                  canPlay &&
                                                      board.landing(column) >= 0
                                                  ? () => setState(
                                                      () => selected = column,
                                                    )
                                                  : null,
                                              child: Column(
                                                children: List.generate(6, (
                                                  row,
                                                ) {
                                                  final slot = row * 7 + column;
                                                  return Expanded(
                                                    child: Center(
                                                      child: FractionallySizedBox(
                                                        widthFactor: .84,
                                                        heightFactor: .84,
                                                        child: LayoutBuilder(
                                                          builder: (context, cell) => Center(
                                                            child: Piece(
                                                              side:
                                                                  slot ==
                                                                      previewSlot
                                                                  ? board.turn
                                                                  : board
                                                                        .cells[slot],
                                                              size: cell
                                                                  .biggest
                                                                  .shortestSide,
                                                              preview:
                                                                  slot ==
                                                                  previewSlot,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  );
                                                }),
                                              ),
                                            ),
                                          ),
                                        );
                                      }),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                FilledButton(
                                  onPressed: selected != null && canPlay
                                      ? () => commit(selected!)
                                      : null,
                                  child: Text(
                                    widget.solo ? 'Drop piece' : 'Confirm move',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (chat) SizedBox(height: dockHeight, child: dock()),
              ],
            );
          },
        ),
      ),
    );
  }
}

class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.messages,
    required this.onChange,
    this.onClose,
  });
  final List<String> messages;
  final ValueChanged<List<String>> onChange;
  final VoidCallback? onClose;
  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  late final List<String> messages = List.of(widget.messages);
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void send() {
    final message = input.text.trim();
    if (message.isEmpty) return;
    setState(() => messages.add(message));
    widget.onChange(List.of(messages));
    input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
        child: Column(
          children: [
            if (widget.onClose != null)
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Local chat preview',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close chat',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            Expanded(
              child: messages.isEmpty
                  ? const Center(child: Text('Messages stay on this phone.'))
                  : ListView.builder(
                      reverse: true,
                      itemCount: messages.length,
                      itemBuilder: (context, index) => Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            vertical: 7,
                            horizontal: 12,
                          ),
                          decoration: BoxDecoration(
                            color: colors.secondaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            messages[messages.length - 1 - index],
                            style: TextStyle(
                              color: colors.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    maxLength: 500,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => send(),
                    decoration: const InputDecoration(
                      hintText: 'Write a message',
                      counterText: '',
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Save preview message',
                  onPressed: send,
                  icon: const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ],
        ),
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
  });
  final AppUpdates? updates;
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
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Appearance'),
          trailing: DropdownButton<ThemeMode>(
            value: ThemeMode.values.byName(
              widget.data['theme'] as String? ?? 'dark',
            ),
            items: const [
              DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
              DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
            ],
            onChanged: (value) {
              if (value != null) {
                widget.onTheme(value);
                setState(() {});
              }
            },
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.volume_up_outlined),
          title: const Text('Game sound effects'),
          value: widget.data['effects'] != false,
          onChanged: (value) => setState(() => widget.write('effects', value)),
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
