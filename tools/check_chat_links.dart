import '../lib/chat_links.dart';
import '../lib/chatmail.dart';

void check(bool condition, String scenario) {
  if (!condition) throw StateError(scenario);
}

void main() {
  const text =
      'Try ironrods.com, www.ironrods.com or '
      '(http://ironrods.com/guide_(v2)). '
      'There is also HTTPS://IRONRODS.COM:8443/?page=2#next.';
  final links = chatLinks(text).toList();
  final targets = links.map((link) => link.uri.toString()).join(' ');
  check(
    targets ==
        'https://ironrods.com https://www.ironrods.com '
            'http://ironrods.com/guide_(v2) '
            'https://ironrods.com:8443/?page=2#next',
    'Recognize bare domains and both web schemes, keeping path punctuation.',
  );
  check(
    text.substring(links[2].start, links[2].end) ==
        'http://ironrods.com/guide_(v2)',
    'Leave surrounding punctuation in the message.',
  );
  check(
    chatLinks(
      'me@ironrods.com ftp://ironrods.com https://name@ironrods.com 12.50',
    ).isEmpty,
    'Skip email addresses, non-web schemes, credentials, and decimals.',
  );

  const videoId = 'dQw4w9WgXcQ';
  const message =
      'Watch youtu.be/$videoId and www.youtube.com/shorts/$videoId. '
      'See youtube.com/watch?v=$videoId and ironrods.com.';
  final previews = chatLinks(message).toList();
  check(
    previews.length == 4 &&
        previews.take(3).every((link) => youtubeVideoId(link.uri) == videoId) &&
        youtubeVideoId(previews.last.uri) == null,
    'Detect bare YouTube addresses alongside regular website links.',
  );
  check(
    youtubeVideoId(
          Uri.parse('https://youtube.com.example.org/watch?v=$videoId'),
        ) ==
        null,
    'Do not treat other websites as YouTube.',
  );

  FriendMessage attachment(
    String name,
    String viewType, {
    String? mime,
    String? text,
  }) => FriendMessage.fromJson({
    'id': 1,
    'state': 26,
    'viewType': viewType,
    'fileName': name,
    'fileMime': mime,
    'text': text,
  });

  for (final media in [
    attachment('drive.jpg', 'Image', text: 'drive.jpg'),
    attachment('cut.mp4', 'File', mime: 'video/mp4'),
    attachment('recording.m4a', 'Voice'),
  ]) {
    check(
      media.bubbleFilename == null && media.bubbleCaption.isEmpty,
      'Hide the filename on ${media.viewType} attachments.',
    );
  }
  final caption = attachment('drive.jpg', 'Image', text: 'On the road');
  check(caption.bubbleCaption == 'On the road', 'Keep the media caption.');
  final document = attachment('manual.pdf', 'File', mime: 'application/pdf');
  check(document.bubbleFilename == 'manual.pdf', 'Keep ordinary filenames.');
  print('PASS: chat web links, YouTube detection, filenames and captions.');
}
