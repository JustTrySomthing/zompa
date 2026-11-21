import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

ButtonStyle destructiveDialogAction(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  return FilledButton.styleFrom(
    backgroundColor: colors.error,
    foregroundColor: colors.onError,
  );
}

Future<String> readPastedLink(int maxLength) async {
  final ClipboardData? data;
  try {
    data = await Clipboard.getData(Clipboard.kTextPlain);
  } on PlatformException {
    throw const FormatException('Couldn’t read the clipboard.');
  }
  final text = data?.text?.trim() ?? '';
  if (text.isEmpty) throw const FormatException('No link on the clipboard.');
  if (text.length > maxLength) {
    throw const FormatException('The pasted link is too long.');
  }
  return text;
}
