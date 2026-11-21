import 'dart:io';

import 'package:flutter/material.dart';

class ChatAvatar extends StatelessWidget {
  const ChatAvatar(
    this.name, {
    super.key,
    this.photo,
    this.radius = 19,
    this.backgroundColor,
    this.foregroundColor,
  });

  final String name;
  final String? photo;
  final double radius;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final fallback = Text(
      trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase(),
      style: TextStyle(fontSize: radius),
    );
    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      child: photo == null || photo!.isEmpty
          ? fallback
          : ClipOval(
              child: Image.file(
                File(photo!),
                width: radius * 2,
                height: radius * 2,
                cacheWidth:
                    (radius * 2 * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(child: fallback),
              ),
            ),
    );
  }
}

String chatTime(
  BuildContext context,
  int seconds, {
  bool compact = false,
  bool showYear = true,
}) {
  if (seconds <= 0) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  final locale = MaterialLocalizations.of(context);
  final time = locale.formatTimeOfDay(
    TimeOfDay.fromDateTime(date),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  final today = DateTime.now();
  if (DateUtils.isSameDay(date, today)) return time;
  if (compact) {
    return !showYear || date.year == today.year
        ? locale.formatShortMonthDay(date)
        : locale.formatShortDate(date);
  }
  return '${locale.formatShortDate(date)} · $time';
}
