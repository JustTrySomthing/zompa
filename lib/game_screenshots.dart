import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'github_distribution.dart';

Future<void> showGameDetails(
  BuildContext context,
  GithubDistribution? distribution,
  GameRelease game, {
  GameRelease? artwork,
}) => showDialog<void>(
  context: context,
  builder: (_) => _GameDetails(
    distribution: distribution,
    game: game,
    artwork: artwork ?? game,
  ),
);

class _GameDetails extends StatefulWidget {
  const _GameDetails({
    required this.distribution,
    required this.game,
    required this.artwork,
  });

  final GithubDistribution? distribution;
  final GameRelease game, artwork;

  @override
  State<_GameDetails> createState() => _GameDetailsState();
}

class _GameDetailsState extends State<_GameDetails> {
  final _pages = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _turn(int direction) {
    if (!_pages.hasClients) return;
    _pages.animateToPage(
      _index + direction,
      duration: const Duration(milliseconds: 230),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final distribution = widget.distribution;
    final images = distribution == null
        ? const <GameScreenshot>[]
        : widget.artwork.screenshots;
    final description = widget.game.description ?? widget.artwork.description;
    final modeLabels = {
      'solo': 'Single Player',
      'local': 'Pass & Play',
      'online': 'Online',
    };
    final modes = modeLabels.entries
        .where((mode) => widget.game.modes.contains(mode.key))
        .map((mode) => mode.value)
        .join(' · ');
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SizedBox(
        width: 620,
        child: Column(
          children: [
            ListTile(
              title: Text(
                widget.game.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: 'Close game details',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (description != null) ...[
                        Text(description),
                        const SizedBox(height: 8),
                      ],
                      Text(modes, style: Theme.of(context).textTheme.labelLarge),
                      if (images.isNotEmpty && distribution != null) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          height: (constraints.maxHeight * 0.8)
                              .clamp(160.0, 480.0)
                              .toDouble(),
                          child: PageView.builder(
                            controller: _pages,
                            itemCount: images.length,
                            onPageChanged: (index) => setState(() => _index = index),
                            itemBuilder: (context, index) => CatalogGameImage(
                              distribution: distribution,
                              game: widget.artwork,
                              file: images[index].file,
                              label: images[index].label,
                            ),
                          ),
                        ),
                      ],
                      if (images.length > 1)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              tooltip: 'Previous screenshot',
                              onPressed: _index == 0 ? null : () => _turn(-1),
                              icon: const Icon(Icons.chevron_left),
                            ),
                            Text('${_index + 1} / ${images.length}'),
                            IconButton(
                              tooltip: 'Next screenshot',
                              onPressed: _index == images.length - 1
                                  ? null
                                  : () => _turn(1),
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CatalogGameImage extends StatefulWidget {
  const CatalogGameImage({
    super.key,
    required this.distribution,
    required this.game,
    required this.file,
    this.label,
    this.fit = BoxFit.contain,
    this.fallback,
  });

  final GithubDistribution distribution;
  final GameRelease game;
  final String file;
  final String? label;
  final BoxFit fit;
  final Widget? fallback;

  @override
  State<CatalogGameImage> createState() => _CatalogGameImageState();
}

class _CatalogGameImageState extends State<CatalogGameImage>
    with AutomaticKeepAliveClientMixin {
  late final _bytes = widget.distribution.gameImage(widget.game, widget.file);

  @override
  bool get wantKeepAlive => widget.label != null;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final fallback =
        widget.fallback ?? const Center(child: Text('Screenshot unavailable'));
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) return fallback;
        if (!snapshot.hasData) {
          return widget.fallback ??
              const Center(child: CircularProgressIndicator());
        }
        return Image.memory(
          snapshot.data!,
          semanticLabel: widget.label,
          excludeFromSemantics: widget.label == null,
          fit: widget.fit,
          errorBuilder: (_, _, _) => fallback,
        );
      },
    );
  }
}
