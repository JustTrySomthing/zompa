import 'github_distribution.dart';

/// Identifies one official package. Download URLs always come from the catalog.
class GameLink {
  GameLink.fromRelease(GameRelease release)
    : id = release.id,
      build = release.build,
      sha = release.asset.sha;

  GameLink._(this.id, this.build, this.sha);

  static const host = 'justtrysomthing.github.io';
  static const path = '/zompa/game/';
  static const legacyPath = '/zompado/game/';
  final String id;
  final int build;
  final String sha;

  static GameLink? parse(String input) {
    final text = input.trim();
    if (text.length > 512) return null;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != host ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        (uri.path != path && uri.path != legacyPath) ||
        uri.hasFragment)
      return null;
    final Map<String, List<String>> query;
    try {
      query = uri.queryParametersAll;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    if (query.length != 3 || query.values.any((values) => values.length != 1)) {
      return null;
    }
    final id = query['id']?.single ?? '';
    final buildText = query['build']?.single ?? '';
    final sha = query['sha']?.single ?? '';
    if (id.length > 64 ||
        !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(id) ||
        !RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(buildText) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha))
      return null;
    final build = int.tryParse(buildText);
    return build == null || build > 2147483647
        ? null
        : GameLink._(id, build, sha);
  }

  bool matches(GameRelease game) =>
      game.id == id && game.build == build && game.asset.sha == sha;

  @override
  String toString() => _url(path);

  // Keep private match events readable by earlier app versions.
  String toMatchWire() => _url(legacyPath);

  String _url(String linkPath) => Uri.https(host, linkPath, {
    'id': id,
    'build': '$build',
    'sha': sha,
  }).toString();
}
