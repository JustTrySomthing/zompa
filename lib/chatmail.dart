import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef Json = Map<String, dynamic>;

enum ChatmailIssue implements Exception {
  unavailable,
  request,
  invite,
  encrypted,
}

class Chatmail {
  Chatmail(this.executable, this.accountsDirectory);

  final String executable;
  final Directory accountsDirectory;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  final _calls = StreamController<Json>.broadcast();
  Stream<Json> get calls => _calls.stream;
  final _incoming = StreamController<(int, int)>.broadcast();
  Stream<(int, int)> get incoming => _incoming.stream;
  Process? _process;
  Future<Process>? _starting;
  Future<bool>? _restoring;
  final _requests = <int, Completer<dynamic>>{};
  int _nextRequest = 0;
  int? _account;
  bool _ready = false;
  bool _closed = false;

  Future<Process> _start() async {
    if (_closed) throw ChatmailIssue.unavailable;
    final existing = _process;
    if (existing != null) return existing;
    return _starting ??= _launch();
  }

  Future<Process> _launch() async {
    try {
      await accountsDirectory.create(recursive: true);
      final process = await Process.start(
        executable,
        const [],
        workingDirectory: accountsDirectory.path,
        environment: {
          'DC_ACCOUNTS_PATH': accountsDirectory.path,
          'RUST_LOG': 'off',
        },
      );
      if (_closed) {
        process.kill();
        throw ChatmailIssue.unavailable;
      }
      _process = process;
      process.stderr.drain<void>().ignore();
      process.stdin.done.ignore();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _receive,
            onError: (_) => _stopped(process),
            onDone: () => _stopped(process),
          );
      process.exitCode.then(
        (_) => _stopped(process),
        onError: (_) => _stopped(process),
      );
      return process;
    } on ProcessException {
      throw ChatmailIssue.unavailable;
    } finally {
      _starting = null;
    }
  }

  void _receive(String line) {
    final Object? value;
    try {
      value = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (value is! Json || value['id'] is! int) return;
    final pending = _requests.remove(value['id']);
    if (pending == null) return;
    if (value.containsKey('error')) {
      pending.completeError(ChatmailIssue.request);
    } else {
      pending.complete(value['result']);
    }
  }

  void _stopped(Process process) {
    if (_process != process) return;
    _process = null;
    _ready = false;
    _account = null;
    process.kill();
    final pending = _requests.values.toList();
    _requests.clear();
    for (final response in pending) {
      response.completeError(ChatmailIssue.unavailable);
    }
    if (!_closed) _changes.add(null);
  }

  Future<dynamic> _call(
    String method,
    List<Object?> arguments, {
    Duration? timeout = const Duration(seconds: 15),
  }) async {
    final process = await _start();
    final id = ++_nextRequest;
    final response = Completer<dynamic>();
    _requests[id] = response;
    try {
      process.stdin.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': arguments,
        }),
      );
      return await (timeout == null
          ? response.future
          : response.future.timeout(timeout));
    } finally {
      _requests.remove(id);
    }
  }

  Future<bool> restore() => _restoring ??= _restore().whenComplete(() {
    _restoring = null;
  });

  Future<bool> _restore() async {
    if (_ready) return true;
    final ids = (await _call('get_all_account_ids', const []) as List)
        .cast<int>();
    _account = ids.isEmpty ? null : ids.first;
    final id = _account;
    if (id == null || await _call('is_configured', [id]) != true) return false;
    await _activate(id);
    return true;
  }

  Future<void> exportBackup(String directory) async {
    if (!await restore()) throw ChatmailIssue.unavailable;
    await _call('export_backup', [_accountId, directory, null], timeout: null);
  }

  Future<void> importBackup(String file) async {
    if (await restore()) throw ChatmailIssue.request;
    final id = _account ?? await _call('add_account', const []) as int;
    _account = id;
    try {
      await _call('import_backup', [id, file, null], timeout: null);
      if (await _call('is_configured', [id]) != true)
        throw ChatmailIssue.request;
    } catch (_) {
      await _call('remove_account', [id]);
      _account = null;
      rethrow;
    }
    await _activate(id);
    _changed();
  }

  Future<({String address, String server, int status})?>
  connectionInfo() async {
    if (!await restore()) return null;
    final account = _accountId;
    final self = await _call('get_contact', [account, 1]) as Json;
    final address = self['address'] as String? ?? '';
    final server = await _call('get_config', [
      account,
      'configured_mail_server',
    ]) as String?;
    return (
      address: address,
      server: server == null || server.isEmpty
          ? address.split('@').last
          : server,
      status: await _call('get_connectivity', [account]) as int,
    );
  }

  Future<void> createProfile(String name) async {
    if (_ready) return;
    final id = _account ??= await _call('add_account', const []) as int;
    await _call('set_config', [id, 'displayname', name]);
    await _call('init_transports', [
      id,
      null,
    ], timeout: const Duration(seconds: 100));
    if (await _call('is_configured', [id]) != true) throw ChatmailIssue.request;
    await _activate(id);
  }

  Future<void> _activate(int id) async {
    if (_ready) return;
    await _call('start_io', [id]);
    if (_ready) return;
    final process = _process;
    if (process == null) throw ChatmailIssue.unavailable;
    _ready = true;
    unawaited(_listenForChanges(process));
  }

  Future<void> _listenForChanges(Process process) async {
    try {
      while (!_closed && _process == process) {
        final batch = await _call(
          'get_next_event_batch',
          const [],
          timeout: null,
        ) as List;
        if (_closed || _process != process) return;
        var hasChanges = false;
        for (final entry in batch.cast<Json>()) {
          if (entry['contextId'] != _account) continue;
          final event = entry['event'] as Json;
          final kind = event['kind'] as String;
          if (kind == 'IncomingCall' ||
              kind == 'IncomingCallAccepted' ||
              kind == 'OutgoingCallAccepted' ||
              kind == 'CallEnded') {
            _calls.add(event);
          }
          if (kind == 'IncomingMsg' &&
              event['chatId'] is int &&
              event['msgId'] is int) {
            _incoming.add((event['chatId'] as int, event['msgId'] as int));
          }
          hasChanges =
              hasChanges ||
              kind.startsWith('Chat') ||
              kind.startsWith('Msg') ||
              kind.startsWith('Securejoin') ||
              kind.startsWith('IncomingMsg') ||
              kind.contains('Reaction') ||
              kind == 'ConnectivityChanged';
        }
        if (hasChanges) _changes.add(null);
      }
    } catch (_) {
      if (!_closed && _process == process) _stopped(process);
    }
  }

  int get _accountId {
    if (!_ready || _account == null) throw ChatmailIssue.unavailable;
    return _account!;
  }

  Future<void> _trashWrite = Future.value();

  File _trashFile(int account) =>
      File('${accountsDirectory.parent.path}/chat-trash-$account.json');

  Future<Set<int>> _trashedChats(int account) async {
    final file = _trashFile(account);
    if (!await file.exists()) return {};
    return (jsonDecode(await file.readAsString()) as List).cast<int>().toSet();
  }

  Future<void> _changeTrash(int account, Set<int> chats, {required bool add}) {
    final operation = _trashWrite.then((_) async {
      final ids = await _trashedChats(account);
      if (add) {
        ids.addAll(chats);
      } else {
        ids.removeAll(chats);
      }
      final file = _trashFile(account);
      final staging = File('${file.path}.tmp');
      await staging.writeAsString(jsonEncode(ids.toList()), flush: true);
      await staging.rename(file.path);
      _changed();
    });
    _trashWrite = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> restoreTrash(int? chat) async {
    final account = _accountId;
    final ids = chat == null ? await _trashedChats(account) : {chat};
    for (final id in ids) {
      // Restored chats return to Inbox, even when moved from Archive.
      await _call('set_chat_visibility', [account, id, 'Normal']);
      await _changeTrash(account, {id}, add: false);
    }
  }

  Future<void> emptyTrash() async {
    final account = _accountId;
    for (final id in await _trashedChats(account)) {
      await _call('delete_chat', [account, id]);
      await _changeTrash(account, {id}, add: false);
    }
  }

  Future<List<FriendChat>> chats({
    bool archived = false,
    bool trash = false,
  }) async {
    final account = _accountId;
    final hidden = await _trashedChats(account);
    final ids = trash
        ? hidden.toList().reversed.toList()
        : (await _call('get_chatlist_entries', [
            account,
            archived ? 3 : 2,
            null,
            null,
          ]) as List).cast<int>().where((id) => !hidden.contains(id)).toList();
    if (ids.isEmpty) return const [];
    final result =
        await _call('get_chatlist_items_by_entries', [account, ids]) as Json;
    return [
      for (final id in ids)
        if (result['$id'] case final Json chat
            when chat['kind'] == 'ChatListItem' &&
                chat['chatType'] == 'Single' &&
                chat['isSelfTalk'] != true &&
                chat['isDeviceTalk'] != true &&
                chat['isEncrypted'] == true)
          FriendChat(
            id,
            chat['name'] as String,
            chat['summaryText2'] as String,
            chat['freshMessageCounter'] as int,
            photo: chat['avatarPath'] as String?,
            archived: chat['isArchived'] == true,
            muted: chat['isMuted'] == true,
          ),
    ];
  }

  void _changed() {
    if (!_closed) _changes.add(null);
  }

  Future<void> manageChat(int chat, String action) async {
    final account = _accountId;
    if (action == 'delete') {
      await _changeTrash(account, {chat}, add: true);
      return;
    }
    final (method, extra) = switch (action) {
      'archive' => ('set_chat_visibility', ['Archived']),
      'restore' => ('set_chat_visibility', ['Normal']),
      'mute' => (
        'set_chat_mute_duration',
        [
          {'kind': 'Forever'},
        ],
      ),
      'unmute' => (
        'set_chat_mute_duration',
        [
          {'kind': 'NotMuted'},
        ],
      ),
      'read' => ('marknoticed_chat', []),
      'unread' => ('markfresh_chat', []),
      'block' => ('block_chat', []),
      _ => throw ArgumentError.value(action),
    };
    await _call(method, [account, chat, ...extra]);
    _changed();
  }

  Future<bool> dataSaver() async =>
      await _call('get_config', [_accountId, 'media_quality']) == '1';

  Future<void> setDataSaver(bool value) async {
    await _call('set_config', [_accountId, 'media_quality', value ? '1' : '0']);
  }

  Future<void> react(int id, String? emoji) async {
    await _call('send_reaction', [
      _accountId,
      id,
      [if (emoji != null) emoji],
    ]);
    _changed();
  }

  Future<void> deleteMessage(int id) async {
    await _call('delete_messages', [
      _accountId,
      [id],
    ]);
    _changed();
  }

  Future<void> toggleSaved(FriendMessage message) async {
    if (message.savedId case final id?) {
      await deleteMessage(id);
    } else {
      await _call('save_msgs', [
        _accountId,
        [message.id],
      ]);
      _changed();
    }
  }

  Future<List<FriendMessage>> savedMessages() async {
    final account = _accountId;
    final chat = await _call('get_chat_id_by_contact_id', [account, 1]) as int?;
    if (chat == null || chat == 0) return [];
    final ids = (await _call('get_message_ids', [
      account,
      chat,
      false,
      false,
    ]) as List).cast<int>();
    final saved = <FriendMessage>[];
    for (var offset = 0; offset < ids.length; offset += 80) {
      final batch = ids.reversed.skip(offset).take(80).toList();
      saved.addAll(await _messages(account, batch));
    }
    return saved;
  }

  Future<List<FriendMessage>> _messages(int account, List<int> ids) async {
    if (ids.isEmpty) return [];
    final result = await _call('get_messages', [account, ids]) as Json;
    return [
      for (final id in ids)
        if (result['$id'] case final Json row when row['kind'] == 'message')
          FriendMessage.fromJson(row),
    ];
  }

  Future<List<ChatContact>> contacts({bool blocked = false}) async {
    final values =
        (await (blocked
                ? _call('get_blocked_contacts', [_accountId])
                : _call('get_contacts', [_accountId, 0, null])))
            as List;
    return [
      for (final value in values.cast<Json>())
        if ((value['id'] as int) > 9) ChatContact.fromJson(value),
    ];
  }

  Future<int> openContact(int id) async =>
      (await _call('create_chat_by_contact_id', [_accountId, id])) as int;

  Future<void> manageContact(int id, String action) async {
    final method = switch (action) {
      'block' => 'block_contact',
      'unblock' => 'unblock_contact',
      'delete' => 'delete_contact',
      _ => throw ArgumentError.value(action),
    };
    await _call(method, [_accountId, id]);
    if (!_closed) _changes.add(null);
  }

  Future<({String name, String bio, String? photo})> profile() async {
    final self = await _call('get_contact', [_accountId, 1]) as Json;
    return (
      name:
          (await _call('get_config', [_accountId, 'displayname'])) as String? ??
          '',
      bio:
          (await _call('get_config', [_accountId, 'selfstatus'])) as String? ??
          '',
      photo: self['profileImage'] as String?,
    );
  }

  Future<void> editProfile(String name, String bio, {String? avatar}) async {
    final account = _accountId;
    await _call('set_config', [account, 'displayname', name]);
    await _call('set_config', [account, 'selfstatus', bio]);
    if (avatar != null)
      await _call('set_config', [account, 'selfavatar', avatar]);
  }

  Future<String> contactCard(int id) async => (await _call('make_vcard', [
    _accountId,
    [id],
  ])) as String;

  Future<String> invite() async =>
      await _call('get_chat_securejoin_qr_code', [_accountId, null]) as String;

  Future<List<(int, int)>> qrModules(String invite) async {
    final svg = await _call('create_qr_svg', [invite]) as String;
    final modules = [
      for (final match in RegExp(r'M(\d+),(\d+)h1v1h-1z').allMatches(svg))
        (int.parse(match[1]!), int.parse(match[2]!)),
    ];
    if (modules.isEmpty ||
        modules.any((module) => module.$1 >= 177 || module.$2 >= 177)) {
      throw ChatmailIssue.request;
    }
    return modules;
  }

  Future<int> acceptInvite(String value) async {
    final id = _accountId;
    final kind = await _call('check_qr', [id, value]) as Json;
    if (kind['kind'] != 'askVerifyContact') throw ChatmailIssue.invite;
    return await _call('secure_join', [id, value]) as int;
  }

  Future<FriendThread> thread(int chat, {int limit = 60}) async {
    final account = _accountId;
    final info = await _call('get_full_chat_by_id', [account, chat]) as Json;
    final ids = (await _call('get_message_ids', [
      account,
      chat,
      false,
      false,
    ]) as List).cast<int>();
    final recent = ids
        .skip(ids.length > limit ? ids.length - limit : 0)
        .toList();
    return FriendThread(
      info['name'] as String,
      info['isEncrypted'] == true && info['canSend'] == true,
      await _messages(account, recent),
      ids.length > recent.length,
    );
  }

  Future<List<FriendMessage>> matchHistory(int chat, String id) =>
      _search(chat, id);

  Future<List<FriendMessage>> _search(int? chat, String id) async {
    final account = _accountId;
    final ids = (await _call('search_messages', [account, id, chat]) as List)
        .cast<int>();
    final records = <FriendMessage>[];
    for (var offset = 0; offset < ids.length; offset += 80) {
      final batch = ids.skip(offset).take(80).toList();
      final messages = await _call('get_messages', [account, batch]) as Json;
      records.addAll([
        for (final id in batch)
          if (messages['$id'] case final Json message
              when message['kind'] == 'message')
            FriendMessage.fromJson(message),
      ]);
    }
    return records;
  }

  Future<List<FriendMessage>> recentMatchMessages(String marker) =>
      _search(null, marker);

  Future<({String name, FriendMessage message})?> notificationMessage(
    int chat,
    int id, {
    bool forDelivery = true,
  }) async {
    final account = _accountId;
    final info = await _call('get_full_chat_by_id', [account, chat]) as Json;
    if (info['chatType'] != 'Single' ||
        info['isEncrypted'] != true ||
        info['isSelfTalk'] == true ||
        info['isDeviceChat'] == true ||
        (forDelivery && info['isMuted'] == true) ||
        info['isContactRequest'] == true)
      return null;
    final messages = await _call('get_messages', [
      account,
      [id],
    ]) as Json;
    if (messages['$id'] case final Json message
        when message['kind'] == 'message') {
      final result = FriendMessage.fromJson(message);
      if (result.chat == chat &&
          !result.outgoing &&
          result.encrypted &&
          (!result.info || message['viewType'] == 'Call') &&
          (!forDelivery || result.state == 10)) {
        return (name: info['name'] as String, message: result);
      }
    }
    return null;
  }

  Future<void> markSeen(List<int> messages) async {
    if (messages.isNotEmpty)
      await _call('markseen_msgs', [_accountId, messages]);
  }

  Future<String> iceServers() async =>
      await _call('ice_servers', [_accountId]) as String;

  Future<Json> _voiceChat(int chat) async {
    final account = _accountId;
    final info = await _call('get_full_chat_by_id', [account, chat]) as Json;
    if (info['isEncrypted'] != true ||
        info['chatType'] != 'Single' ||
        info['isSelfTalk'] == true ||
        info['isDeviceChat'] == true ||
        info['isContactRequest'] == true ||
        info['canSend'] != true) {
      throw ChatmailIssue.encrypted;
    }
    return info;
  }

  Future<({String name, String offer, int secondsLeft, bool video})?>
  incomingVoiceCall(
    int chat,
    int message, {
    bool fromNotification = false,
  }) async {
    final info = await _voiceChat(chat);
    if (fromNotification &&
        (info['isMuted'] == true ||
            await _call('get_config', [_accountId, 'who_can_call_me']) ==
                '2')) {
      return null;
    }
    final entries = await _call('get_messages', [
      _accountId,
      [message],
    ]) as Json;
    if (entries['$message'] case final Json call
        when call['kind'] == 'message' &&
            call['chatId'] == chat &&
            call['showPadlock'] == true &&
            call['viewType'] == 'Call' &&
            call['fromId'] is int &&
            (call['fromId'] as int) > 1 &&
            call['timestamp'] is int) {
      final details = await _call('call_info', [_accountId, message]) as Json;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final remaining = ((call['timestamp'] as int) + 120 - now).clamp(0, 118);
      if ((details['state'] as Json)['kind'] == 'Alerting' &&
          details['sdpOffer'] is String &&
          remaining > 0) {
        return (
          name: info['name'] as String,
          offer: details['sdpOffer'] as String,
          secondsLeft: remaining,
          video: details['hasVideo'] == true,
        );
      }
    }
    return null;
  }

  Future<bool> callIsRinging(int message) async {
    final result = await _call('call_info', [_accountId, message]) as Json;
    return (result['state'] as Json)['kind'] == 'Alerting';
  }

  Future<int> placeCall(int chat, String offer) async {
    await _voiceChat(chat);
    return await _call('place_outgoing_call', [_accountId, chat, offer, false])
        as int;
  }

  Future<void> acceptCall(int message, String answer) async {
    await _call('accept_incoming_call', [_accountId, message, answer]);
  }

  Future<void> endCall(int message) async {
    await _call('end_call', [_accountId, message]);
  }

  Future<void> send(
    int chat,
    String message, {
    String? file,
    String? filename,
    String? mediaType,
  }) async {
    final account = _accountId;
    final info = await _call('get_full_chat_by_id', [account, chat]) as Json;
    if (info['isEncrypted'] != true ||
        info['chatType'] != 'Single' ||
        info['canSend'] != true) {
      throw ChatmailIssue.encrypted;
    }
    if (file == null) {
      await _call('misc_send_text_message', [account, chat, message]);
    } else {
      await _call('send_msg', [
        account,
        chat,
        {
          'text': message,
          'file': file,
          'filename': filename,
          'viewtype': mediaType ?? 'File',
        },
      ]);
    }
  }

  void close() {
    _closed = true;
    final process = _process;
    if (process != null) _stopped(process);
    _changes.close();
    _incoming.close();
    _calls.close();
  }
}

class ChatContact {
  ChatContact.fromJson(Json value)
    : id = value['id'] as int,
      name = value['displayName'] as String? ?? value['name'] as String? ?? '',
      address = value['address'] as String? ?? '',
      photo = value['profileImage'] as String?;

  final int id;
  final String name, address;
  final String? photo;
}

class FriendChat {
  const FriendChat(
    this.id,
    this.name,
    this.preview,
    this.unread, {
    this.photo,
    this.archived = false,
    this.muted = false,
  });
  final int id;
  final String name, preview;
  final int unread;
  final String? photo;
  final bool archived, muted;
}

class FriendThread {
  const FriendThread(this.name, this.canSend, this.messages, this.hasOlder);
  final String name;
  final bool canSend, hasOlder;
  final List<FriendMessage> messages;
}

class FriendMessage {
  FriendMessage.fromJson(Json message)
    : id = message['id'] as int,
      state = message['state'] as int,
      chat = message['chatId'] as int? ?? 0,
      text = (message['text'] as String?) ?? '',
      filename = message['fileName'] as String?,
      file = message['file'] as String?,
      mime = message['fileMime'] as String?,
      timestamp = message['timestamp'] as int? ?? 0,
      viewType = message['viewType'] as String? ?? 'Text',
      sender = message['sender'] is Json
          ? ChatContact.fromJson(message['sender'] as Json)
          : null,
      savedId = message['savedMessageId'] as int?,
      reactions = [
        for (final row
            in ((message['reactions'] as Json?)?['reactions'] as List? ??
                    const [])
                .cast<Json>())
          (
            emoji: row['emoji'] as String,
            count: row['count'] as int,
            mine: row['isFromSelf'] == true,
          ),
      ],
      outgoing = message['fromId'] == 1,
      info = message['isInfo'] == true,
      encrypted = message['showPadlock'] == true;

  final int id, state, chat, timestamp;
  final int? savedId;
  final ChatContact? sender;
  final List<({String emoji, int count, bool mine})> reactions;
  final String text, viewType;
  final String? file, filename, mime;
  final bool outgoing, info, encrypted;

  String? get delivery => switch (state) {
    20 => 'Sending',
    24 => 'Couldn’t send',
    _ => null,
  };
}
