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

// Some dialogs need more vertical space than is available above the keyboard.
Widget fitDialogToKeyboard(Widget dialog, {double minimumHeight = 320}) =>
    LayoutBuilder(
      builder: (context, constraints) {
        final keyboard = MediaQuery.viewInsetsOf(context).bottom;
        final availableHeight = constraints.maxHeight - keyboard;
        final compact = availableHeight < minimumHeight;
        final theme = Theme.of(context);
        return Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: SingleChildScrollView(
            primary: false,
            hitTestBehavior: HitTestBehavior.deferToChild,
            child: SizedBox(
              height: compact ? minimumHeight : availableHeight,
              child: MediaQuery.removeViewInsets(
                context: context,
                removeBottom: true,
                child: Theme(
                  data: compact
                      ? theme.copyWith(
                          dialogTheme: theme.dialogTheme.copyWith(
                            alignment: Alignment.topCenter,
                          ),
                        )
                      : theme,
                  child: dialog,
                ),
              ),
            ),
          ),
        );
      },
    );
