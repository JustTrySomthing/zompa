import 'dart:io';

import 'package:flutter/services.dart';

const _host = MethodChannel('io.zompado.host');

class ChatFile {
  const ChatFile(this.path, this.name);

  final String path, name;

  static Future<ChatFile?> pick(String type) async {
    final result = await _host.invokeMapMethod<String, String>(
      'pickChatFile',
      type,
    );
    if (result == null) return null;
    return ChatFile(result['path']!, result['name']!);
  }

  static Future<ChatFile?> card(String vcard) async {
    final result = await _host.invokeMapMethod<String, String>(
      'stageContactCard',
      vcard,
    );
    if (result == null) return null;
    return ChatFile(result['path']!, result['name']!);
  }

  Future<void> discard() async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // The temporary file may have already been removed by Android.
    }
  }
}
