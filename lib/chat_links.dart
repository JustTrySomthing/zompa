typedef ChatLink = ({int start, int end, Uri uri});

final _webLink = RegExp(
  r'(?<![\p{L}\p{N}_@./+\-])(?:https?://[^\s<>"\u0000-\u001f]+'
  r'|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+'
  r'(?:xn--[a-z0-9-]{2,59}|[a-z]{2,63})(?![\p{L}\p{N}_@-])'
  r'(?::\d+)?(?:[/?#][^\s<>"\u0000-\u001f]*)?)',
  caseSensitive: false,
  unicode: true,
);
final _httpScheme = RegExp(r'^https?://', caseSensitive: false);
const _trailingPunctuation = '.,!?;:\u2019\u201d';
const _closingPairs = {')': '(', ']': '[', '}': '{'};

Iterable<ChatLink> chatLinks(String message) sync* {
  for (final match in _webLink.allMatches(message)) {
    final candidate = match.group(0)!;
    var end = candidate.length;
    final extraClosers = <String, int>{};
    while (end > 0) {
      final trailing = candidate[end - 1];
      if (_trailingPunctuation.contains(trailing)) {
        end--;
        continue;
      }
      final opening = _closingPairs[trailing];
      if (opening == null) break;
      final extra = extraClosers.putIfAbsent(
        trailing,
        () =>
            trailing.allMatches(candidate).length -
            opening.allMatches(candidate).length,
      );
      if (extra <= 0) break;
      extraClosers[trailing] = extra - 1;
      end--;
    }
    final target = candidate.substring(0, end);
    final uri = Uri.tryParse(
      _httpScheme.hasMatch(target) ? target : 'https://$target',
    );
    if (uri == null || uri.host.isEmpty || uri.authority.contains('@'))
      continue;
    yield (start: match.start, end: match.start + target.length, uri: uri);
  }
}

String? youtubeVideoId(Uri uri) {
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments;
  final String? id;
  if (host == 'youtu.be' && segments.isNotEmpty) {
    id = segments.first;
  } else if (const {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
  }.contains(host)) {
    id = switch (segments) {
      ['watch'] => uri.queryParameters['v'],
      ['shorts' || 'embed' || 'live', final video, ...] => video,
      _ => null,
    };
  } else {
    return null;
  }
  return id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ? id : null;
}
