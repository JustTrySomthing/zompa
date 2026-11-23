import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'github_distribution.dart';

const installedVersion = '0.5.47';
const installedBuild = 56;

class AppUpdates extends ChangeNotifier {
  AppUpdates(this.distribution, this.host, this.data, this.write);
  final GithubDistribution distribution;
  final MethodChannel host;
  final Map<String, dynamic> data;
  final void Function(String, dynamic) write;
  AppRelease? available;
  bool checking = false;
  bool downloading = false;
  bool _showCheckResult = false;
  bool _statusFromCheck = false;
  bool disposed = false;
  String? status;
  bool get automatic => data['autoUpdates'] != false;

  Future<void> syncSchedule() async {
    try {
      await host.invokeMethod<void>('scheduleUpdates', {'enabled': automatic});
    } on PlatformException catch (_) {
      // Foreground checks remain available on devices that can't schedule the job.
    }
  }

  void setAutomatic(bool value) {
    write('autoUpdates', value);
    syncSchedule();
    if (!disposed) notifyListeners();
    if (value) checkIfDue();
  }

  Future<void> checkIfDue() async {
    if (!automatic) return;
    final last = DateTime.tryParse(data['lastUpdateCheck'] as String? ?? '');
    var cachedBuild = data['lastAvailableBuild'] as int? ?? 0;
    try {
      final background =
          await host.invokeMethod<int>('backgroundUpdateBuild') ?? 0;
      if (background > cachedBuild) cachedBuild = background;
    } on PlatformException catch (_) {
      // Fall back to the timestamp of the last foreground check.
    }
    if (!automatic || disposed) return;
    if (last == null ||
        DateTime.now().difference(last) >= const Duration(days: 1) ||
        cachedBuild > (available?.build ?? installedBuild)) {
      await check(manual: false);
    }
  }

  Future<void> check({bool manual = true}) async {
    if (disposed || downloading) return;
    if (manual) {
      _showCheckResult = true;
      _statusFromCheck = true;
      status = 'Checking GitHub…';
    }
    if (checking) {
      if (manual) notifyListeners();
      return;
    }
    checking = true;
    notifyListeners();
    try {
      final release = await distribution.appRelease();
      if (disposed) return;
      final previousBuild = available?.build;
      available = release.build > installedBuild ? release : null;
      write('lastAvailableBuild', available?.build ?? 0);
      write('lastUpdateCheck', DateTime.now().toUtc().toIso8601String());
      if (_statusFromCheck) {
        status = available == null
            ? 'You’re up to date ($installedVersion).'
            : 'Version ${release.version} is available.';
      } else if (previousBuild != available?.build) {
        status = null;
      }
    } catch (_) {
      if (_showCheckResult) status = 'Couldn’t check for updates. Try again.';
    } finally {
      _showCheckResult = false;
      checking = false;
      if (!disposed) notifyListeners();
    }
  }

  Future<void> install() async {
    final release = available;
    if (checking || downloading || release == null || disposed) return;
    downloading = true;
    _statusFromCheck = false;
    status = 'Downloading version ${release.version}…';
    notifyListeners();
    File? staged;
    try {
      staged = await distribution.stageUpdate(release);
      if (disposed) return;
      final result = await host.invokeMethod<String>('installUpdate', {
        'path': staged.path,
        'build': release.build,
      });
      status = result == 'permission'
          ? 'Allow installs from Zompa in Android settings, then tap Install again.'
          : 'Follow the Android installer to complete the update.';
    } on PlatformException catch (error) {
      status = error.message ?? 'Android couldn’t open the update.';
    } catch (_) {
      status = 'Couldn’t download a verified update. Try again.';
    } finally {
      downloading = false;
      if (!disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
