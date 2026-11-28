import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/github_distribution.dart';

class FixtureClient implements HttpClient {
  FixtureClient(this.body);

  final List<int> body;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => FixtureRequest(body);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixtureRequest implements HttpClientRequest {
  FixtureRequest(this.body);

  final List<int> body;

  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = FixtureHeaders();

  @override
  Future<HttpClientResponse> close() async => FixtureResponse(body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixtureHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixtureResponse extends Stream<List<int>> implements HttpClientResponse {
  FixtureResponse(this.body);

  final List<int> body;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final chunks = Stream<List<int>>.fromIterable([
      for (var start = 0; start < body.length; start += 4096)
        body.sublist(start, (start + 4096).clamp(0, body.length)),
    ]);
    return chunks.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object> entry(int build) => {
  'id': 'fortress-badlands',
  'title': 'Fortress Siege — Final Conquest',
  'version': '1.4.$build',
  'build': build,
  'modes': ['solo', 'online', 'local'],
  'format': 'zomp',
  'url':
      'https://github.com/$githubOwner/$gamesRepository/releases/download/'
      'fortress-v1.4.$build/fortress-v1.4.$build.zomp',
  'sha256': 'a' * 64,
  'size': 7847742,
  'minZompaBuild': 62,
  'onlineProtocol': 'turns-v2',
};

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  const archivedBuilds = 400;
  final payload = utf8.encode(
    jsonEncode({
      'schema': 2,
      'games': [entry(archivedBuilds + 1)],
      'archive': [for (var i = 1; i <= archivedBuilds; i++) entry(i)],
    }),
  );
  check(payload.length > 128 * 1024, 'Fixture must exceed the old limit');
  final distribution = GithubDistribution(Directory.systemTemp);
  await HttpOverrides.runZoned(() async {
    final current = await distribution.catalog();
    check(current.single.build == archivedBuilds + 1, 'Latest game is hidden');
    final all = await distribution.catalog(includeArchive: true);
    check(all.length == archivedBuilds + 1, 'Archived builds were lost');
  }, createHttpClient: (_) => FixtureClient(payload));
  await HttpOverrides.runZoned(() async {
    try {
      await distribution.appRelease();
    } on FormatException catch (error) {
      check(error.message == 'Release metadata is too large.', error.message);
      return;
    }
    throw StateError('Oversized Android update metadata was accepted');
  }, createHttpClient: (_) => FixtureClient(payload));
  final size = payload.length;
  print('PASS: $size-byte catalog with all archived builds');
}
