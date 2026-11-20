/// Delta Chat offers video and data alongside audio even when calling without video.
/// Accept one encrypted audio section and optional video and data sections.
bool validVoiceSdp(Object? value) {
  if (value is! String || value.length > 24576) return false;
  final lines = value.split('\n').map((line) => line.trimRight());
  if (lines.first != 'v=0') return false;
  final media = <String>{};
  for (final line in lines.where((line) => line.startsWith('m='))) {
    final fields = line.substring(2).split(' ');
    if (fields.length < 4 || !media.add(fields.first)) return false;
    final port = int.tryParse(fields[1]);
    if (port == null || port < 0 || port > 65535) return false;
    switch (fields.first) {
      case 'audio':
        if (port == 0 || fields[2] != 'UDP/TLS/RTP/SAVPF') return false;
      case 'video':
        if (fields[2] != 'UDP/TLS/RTP/SAVPF') return false;
      case 'application':
        if (fields[2] != 'UDP/DTLS/SCTP') return false;
      default:
        return false;
    }
  }
  return media.contains('audio');
}
