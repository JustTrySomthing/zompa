import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _host = MethodChannel('io.zompado.host');

class ChatFile {
  const ChatFile(
    this.path,
    this.name,
    this.mime, {
    this.original = false,
    this.voice = false,
  });

  final String path, name, mime;
  final bool original, voice;

  String get mediaType {
    if (original) return 'File';
    if (voice) return 'Voice';
    if (mime == 'image/gif') return 'Gif';
    if (mime.startsWith('image/') && mime != 'image/svg+xml') return 'Image';
    if (mime.startsWith('audio/')) return 'Audio';
    if (mime.startsWith('video/')) return 'Video';
    return 'File';
  }

  static ChatFile? _from(
    Map<String, String>? map, {
    bool original = false,
    bool voice = false,
  }) => map == null
      ? null
      : ChatFile(
          map['path']!,
          map['name']!,
          map['mime'] ?? 'application/octet-stream',
          original: original,
          voice: voice,
        );

  static Future<ChatFile?> pick(String type, {bool original = false}) async =>
      _from(
        await _host.invokeMapMethod<String, String>('pickChatFile', type),
        original: original,
      );

  static Future<ChatFile?> record(BuildContext context) async {
    if (await _host.invokeMethod<bool>('requestMicrophone') != true ||
        !context.mounted)
      return null;
    await _host.invokeMethod<void>('startChatRecording');
    bool? keep;
    ChatFile? result;
    try {
      if (context.mounted) {
        keep = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialog) => AlertDialog(
            title: const Text('Recording audio'),
            content: const Text('Tap Done to attach this recording.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialog, true),
                icon: const Icon(Icons.stop),
                label: const Text('Done'),
              ),
            ],
          ),
        );
      }
    } finally {
      result = _from(
        await _host.invokeMapMethod<String, String>('stopChatRecording', {
          'keep': keep == true && context.mounted,
        }),
        voice: true,
      );
      if (keep == true && result == null && context.mounted) {
        throw const FormatException('The recording was unavailable.');
      }
    }
    return result;
  }

  Future<ChatFile?> prepare(bool dataSaver) async {
    if (original ||
        voice ||
        !(mime.startsWith('audio/') || mime.startsWith('video/')))
      return null;
    return _from(
      await _host.invokeMapMethod<String, String>('prepareChatMedia', {
        'path': path,
        'name': name,
        'mime': mime,
        'dataSaver': dataSaver,
      }),
    );
  }

  static Future<bool> download(String path, String name, String? mime) async =>
      await _host.invokeMethod<bool>('downloadChatFile', {
        'path': path,
        'name': name,
        'mime': mime,
      }) ==
      true;

  Future<void> discard() async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // The temporary file may have already been removed by Android or Core.
    }
  }
}
