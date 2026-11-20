import '../lib/voice_sdp.dart';

void main() {
  const header = 'v=0\r\ns=-\r\n';
  const audio = 'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';
  const video = 'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n';
  const data = 'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n';
  final cases = {
    'Zompado audio': (header + audio, true),
    'Delta Chat audio offer with reserved video and data': (
      header + audio + video + data,
      true,
    ),
    'Answer with rejected video': (
      header + audio + video.replaceFirst(' 9 ', ' 0 ') + data,
      true,
    ),
    'Video without audio': (header + video, false),
    'Two audio sections': (header + audio + audio, false),
    'Unencrypted RTP': (header + audio.replaceFirst('UDP/TLS/', ''), false),
    'Rejected audio': (header + audio.replaceFirst(' 9 ', ' 0 '), false),
  };
  for (final MapEntry(key: name, value: (sdp, expected)) in cases.entries) {
    if (validVoiceSdp(sdp) != expected) throw StateError(name);
  }
  print('PASS: accepted encrypted audio-only and Delta Chat offer layouts.');
}
