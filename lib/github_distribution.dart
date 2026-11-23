import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const githubOwner = 'JustTrySomthing';
const appRepository = 'zompa';
const gamesRepository = 'zompa-games';
// Shipped feeds, catalog entries, and installed games can contain old URLs.
String? _previousRepository(String repository) => switch (repository) {
  appRepository => 'zompado',
  gamesRepository => 'zompado-games',
  _ => null,
};

const transferLimit = 256 * 1024 * 1024;

class ReleaseAsset {
  ReleaseAsset.fromJson(
    Map<String, dynamic> json,
    String repository,
    String extension,
  ) : url = Uri.parse(json['url'] as String),
      sha = json['sha256'] as String,
      size = json['size'] as int {
    final path = url.pathSegments;
    if (url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.userInfo.isNotEmpty ||
        url.hasPort ||
        url.hasQuery ||
        url.hasFragment ||
        path.length != 6 ||
        path[0] != githubOwner ||
        (path[1] != repository && path[1] != _previousRepository(repository)) ||
        path[2] != 'releases' ||
        path[3] != 'download' ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(path[4]) ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(path[5]) ||
        !path.last.endsWith(extension) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
        size <= 0 ||
        size > transferLimit) {
      throw const FormatException('Invalid release download.');
    }
  }

  final Uri url;
  final String sha;
  final int size;
}

class GameScreenshot {
  const GameScreenshot(this.file, this.label);

  final String file, label;

  static List<GameScreenshot> parse(Object? value) {
    if (value is! List || value.length > 8) return const [];
    final images = <GameScreenshot>[];
    final seen = <String>{};
    for (final entry in value) {
      if (entry is! Map ||
          entry['file'] is! String ||
          entry['label'] is! String)
        continue;
      final file = entry['file'] as String;
      final label = (entry['label'] as String).trim();
      if (RegExp(r'^shot-[1-8]\.webp$').hasMatch(file) &&
          label.isNotEmpty &&
          label.length <= 100 &&
          seen.add(file)) {
        images.add(GameScreenshot(file, label));
      }
    }
    return List.unmodifiable(images);
  }
}

String? _catalogDescription(Object? value) {
  if (value is! String) return null;
  final description = value.trim();
  if (description.isEmpty || description.runes.length > 600) return null;
  return description;
}

class GameRelease {
  GameRelease.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      title = json['title'] as String,
      version = json['version'] as String,
      build = json['build'] as int,
      modes =
          (json['modes'] as List?)?.cast<String>().toSet() ?? const {'solo'},
      asset = ReleaseAsset.fromJson(json, gamesRepository, '.zomp'),
      hasCover = json['cover'] == 'cover.webp',
      localSaves = json['localSaves'] == true,
      description = _catalogDescription(json['description']),
      screenshots = GameScreenshot.parse(json['screenshots']) {
    if (id.length > 64 ||
        !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(id) ||
        json['format'] != 'zomp' ||
        title.isEmpty ||
        title.length > 90 ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        build < 1 ||
        build > 2147483647 ||
        asset.size > 64 * 1024 * 1024 ||
        !modes.contains('solo')) {
      throw const FormatException('Invalid game catalog entry.');
    }
  }
  final String id, title, version;
  final String? description;
  final int build;
  final ReleaseAsset asset;
  final Set<String> modes;
  final bool hasCover;
  final bool localSaves;
  bool get supportsLocalSaves =>
      localSaves || (id == 'drop-four' && build >= 3);
  final List<GameScreenshot> screenshots;

  Uri imageUrl(String file) => Uri.https(
    'raw.githubusercontent.com',
    '/$githubOwner/$gamesRepository/main/catalog-art/$id/$version/$file',
  );
  Map<String, Object> get playerReference => {
    'id': id,
    'build': build,
    'sha': asset.sha,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'version': version,
    'build': build,
    'format': 'zomp',
    'modes': modes.toList(),
    'url': asset.url.toString(),
    'sha256': asset.sha,
    'size': asset.size,
    if (description != null) 'description': description,
    if (hasCover) 'cover': 'cover.webp',
    if (localSaves) 'localSaves': true,
    if (screenshots.isNotEmpty)
      'screenshots': [
        for (final image in screenshots)
          {'file': image.file, 'label': image.label},
      ],
  };
}

class AppRelease {
  AppRelease.fromJson(Map<String, dynamic> json)
    : version = json['version'] as String,
      build = json['build'] as int,
      asset = ReleaseAsset.fromJson(json, appRepository, '.apk') {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        build < 1 ||
        json['abi'] != 'arm64-v8a') {
      throw const FormatException('Invalid Android release.');
    }
  }
  final String version;
  final int build;
  final ReleaseAsset asset;
}

class GithubDistribution {
  GithubDistribution(this.directory);
  final Directory directory;

  Future<List<GameRelease>> catalog({bool includeArchive = false}) async {
    final json = await _manifest(gamesRepository, 'catalog-v2.json', schema: 2);
    final entries = [
      ...(json['games'] as List),
      if (includeArchive) ...(json['archive'] as List? ?? const []),
    ];
    return entries
        .map(
          (entry) =>
              GameRelease.fromJson(Map<String, dynamic>.from(entry as Map)),
        )
        .toList();
  }

  Future<Uint8List> gameImage(GameRelease game, String file) async {
    if (!(game.hasCover && file == 'cover.webp') &&
        !game.screenshots.any((image) => image.file == file)) {
      throw const FormatException('Unknown game image.');
    }
    const maxBytes = 350 * 1024;
    final uri = game.imageUrl(file);
    final client = _client();
    try {
      final response = await _getWithPreviousRepository(
        client,
        uri,
        gamesRepository,
      );
      if (response.contentLength > maxBytes) {
        throw const FormatException('Game image is too large.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const FormatException('Game image is too large.');
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<AppRelease> appRelease() async => AppRelease.fromJson(
    await _readManifest(
      Uri.https(
        'github.com',
        '/$githubOwner/$appRepository/releases/latest/download/update.json',
        {'check': DateTime.now().microsecondsSinceEpoch.toString()},
      ),
      schema: 1,
      fresh: true,
      repository: appRepository,
    ),
  );

  Future<Map<String, dynamic>> _manifest(
    String repo,
    String name, {
    int schema = 1,
  }) => _readManifest(
    Uri.https('raw.githubusercontent.com', '/$githubOwner/$repo/main/$name'),
    schema: schema,
    repository: repo,
  );

  Future<Map<String, dynamic>> _readManifest(
    Uri url, {
    required int schema,
    bool fresh = false,
    required String repository,
  }) async {
    final client = _client();
    try {
      final response = await _getWithPreviousRepository(
        client,
        url,
        repository,
        fresh: fresh,
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        if (bytes.length + chunk.length > 128 * 1024) {
          throw const FormatException('Release metadata is too large.');
        }
        bytes.addAll(chunk);
      }
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['schema'] != schema)
        throw const FormatException('Unsupported release feed.');
      return json;
    } finally {
      client.close(force: true);
    }
  }

  File gameFile(GameRelease game) =>
      File('${directory.path}/games/${game.id}/${game.build}.zomp');

  Future<File> installGame(GameRelease game) =>
      _download(game.asset, gameFile(game));

  Future<bool> verifyGame(GameRelease game) =>
      _matchesAsset(game.asset, gameFile(game));

  Future<void> removeGame(GameRelease game) async {
    final folder = gameFile(game).parent;
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<File> stageUpdate(AppRelease release) => _download(
    release.asset,
    File('${directory.path}/updates/${release.build}.apk'),
  );

  Future<bool> _matchesAsset(ReleaseAsset asset, File file) async =>
      await file.exists() &&
      await file.length() == asset.size &&
      (await sha256.bind(file.openRead()).first).toString() == asset.sha;

  Future<File> _download(ReleaseAsset asset, File target) async {
    await target.parent.create(recursive: true);
    if (await _matchesAsset(asset, target)) {
      return target;
    }
    final client = _client();
    final scratch = await target.parent.createTemp('.download-');
    final partial = File('${scratch.path}/asset');
    try {
      final response = await _get(client, asset.url);
      var received = 0;
      final output = await partial.open(mode: FileMode.writeOnly);
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > asset.size)
            throw const FormatException('Unexpected download size.');
          await output.writeFrom(chunk);
        }
      } finally {
        await output.close();
      }
      if (received != asset.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              asset.sha) {
        throw const FormatException('The download failed its integrity check.');
      }
      return await partial.rename(target.path);
    } finally {
      client.close(force: true);
      await scratch.delete(recursive: true);
    }
  }

  Future<HttpClientResponse> _getWithPreviousRepository(
    HttpClient client,
    Uri url,
    String repository, {
    bool fresh = false,
  }) async {
    try {
      return await _get(client, url, fresh: fresh);
    } on HttpException catch (error) {
      if (error.message != 'GitHub returned 404.') rethrow;
      final previous = _previousRepository(repository);
      if (previous == null) rethrow;
      final path = url.pathSegments.toList();
      path[1] = previous;
      return _get(client, url.replace(pathSegments: path), fresh: fresh);
    }
  }

  HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 12);

  Future<HttpClientResponse> _get(
    HttpClient client,
    Uri url, {
    bool fresh = false,
  }) async {
    var next = url;
    for (var redirects = 0; redirects <= 4; redirects++) {
      if (next.scheme != 'https' ||
          next.userInfo.isNotEmpty ||
          next.hasPort ||
          !const {
            'github.com',
            'raw.githubusercontent.com',
            'release-assets.githubusercontent.com',
            'objects.githubusercontent.com',
            'github-releases.githubusercontent.com',
          }.contains(next.host)) {
        throw const FormatException('Unexpected download host.');
      }
      final request = await client
          .getUrl(next)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      if (fresh)
        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode == HttpStatus.ok) return response;
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null)
          throw const FormatException('Missing download redirect.');
        next = next.resolve(location);
        continue;
      }
      throw HttpException('GitHub returned ${response.statusCode}.', uri: url);
    }
    throw const FormatException('Too many download redirects.');
  }
}
