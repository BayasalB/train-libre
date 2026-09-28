import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// An in-memory, read-only view of the selected ChatGPT export. No database or
/// network dependency. Only conversation JSON is inspected; media is not read.
class ChatExportReader {
  static const maxInputBytes = 256 * 1024 * 1024;
  static const maxJsonBytes = 128 * 1024 * 1024;
  static const maxTotalJsonBytes = 256 * 1024 * 1024;
  static final _conversationFile = RegExp(
      r'^(?:conversations?|chat_conversations?)(?:[-_]\d+)?\.json$',
      caseSensitive: false);

  ChatExportCatalog read(String fileName, Uint8List bytes) {
    if (bytes.length > maxInputBytes) {
      throw const ChatExportException(
          'Export is too large for on-device review.');
    }
    final sources = <String, String>{};
    final detected = <String>[];
    if (fileName.toLowerCase().endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(bytes);
      var total = 0;
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        detected.add(entry.name);
        final name = entry.name.replaceAll('\\', '/').split('/').last;
        if (!_conversationFile.hasMatch(name)) continue;
        if (entry.size > maxJsonBytes ||
            total + entry.size > maxTotalJsonBytes) {
          throw const ChatExportException(
              'Conversation JSON exceeds the on-device size limit.');
        }
        final content = entry.content;
        total += entry.size;
        sources[entry.name] = utf8.decode(content, allowMalformed: false);
      }
    } else if (fileName.toLowerCase().endsWith('.json')) {
      detected.add(fileName);
      if (bytes.length > maxJsonBytes) {
        throw const ChatExportException(
            'Conversation JSON exceeds the on-device size limit.');
      }
      sources[fileName] = utf8.decode(bytes, allowMalformed: false);
    } else {
      throw ChatExportException(
          'Expected a ChatGPT .zip or conversation .json. Found: $fileName');
    }
    return _readSources(sources, detected);
  }

  /// Unzipped split/chunked JSON files selected together in Files.
  ChatExportCatalog readMany(Map<String, Uint8List> files) {
    final sources = <String, String>{};
    var total = 0;
    for (final entry in files.entries) {
      final name = entry.key.replaceAll('\\', '/').split('/').last;
      if (!_conversationFile.hasMatch(name)) {
        throw ChatExportException(
            'Not a recognized conversation JSON: ${entry.key}');
      }
      if (entry.value.length > maxJsonBytes ||
          total + entry.value.length > maxTotalJsonBytes) {
        throw const ChatExportException(
            'Conversation JSON exceeds the on-device size limit.');
      }
      total += entry.value.length;
      sources[entry.key] = utf8.decode(entry.value, allowMalformed: false);
    }
    return _readSources(sources, files.keys.toList());
  }

  ChatExportCatalog _readSources(
      Map<String, String> sources, List<String> detected) {
    if (sources.isEmpty) {
      throw ChatExportException(
          'No recognized conversation JSON found. Detected: ${detected.take(30).join(', ')}');
    }
    final conversations = <ChatConversation>[];
    final seen = <String>{};
    final warnings = <String>[];
    for (final source in sources.entries) {
      Object? json;
      try {
        json = jsonDecode(source.value);
      } catch (error) {
        throw ChatExportException('${source.key}: malformed JSON ($error)');
      }
      final rows = json is List
          ? json
          : json is Map && json['conversations'] is List
              ? json['conversations'] as List
              : json is Map && _looksLikeConversation(json)
                  ? [json]
                  : null;
      if (rows == null) {
        throw ChatExportException(
            '${source.key}: unrecognized conversation structure. Top-level type: ${json.runtimeType}.');
      }
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        if (row is! Map || !_looksLikeConversation(row)) {
          warnings.add(
              '${source.key} row $i is not a recognized conversation; skipped.');
          continue;
        }
        final conversation = ChatConversation.fromExport(row, source.key, i);
        if (!seen.add(conversation.id)) {
          warnings.add(
              'Duplicate conversation ID ${conversation.id} in ${source.key}; first copy kept.');
          continue;
        }
        conversations.add(conversation);
      }
    }
    if (conversations.isEmpty) {
      throw ChatExportException(
          'No usable conversations found. Detected: ${detected.take(30).join(', ')}');
    }
    return ChatExportCatalog(conversations, detected, warnings);
  }

  bool _looksLikeConversation(Map row) =>
      row['mapping'] is Map || row['messages'] is List;
}

class ChatExportException implements Exception {
  final String message;
  const ChatExportException(this.message);
  @override
  String toString() => message;
}

class ChatExportCatalog {
  final List<ChatConversation> conversations;
  final List<String> detectedFiles;
  final List<String> warnings;
  ChatExportCatalog(this.conversations, this.detectedFiles, this.warnings);

  List<ChatConversation> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return conversations;
    return conversations
        .where((conversation) =>
            conversation.title.toLowerCase().contains(needle) ||
            conversation.allMessages
                .any((m) => m.text.toLowerCase().contains(needle)))
        .toList();
  }
}

class ChatMessage {
  final String id;
  final String role;
  final DateTime? timestamp;

  /// Original offset's wall-clock context; Unix timestamps use device-local.
  final DateTime? dateContext;
  final String? originalTimestamp;
  final String text;
  final List<String> mediaRefs;
  final int sourceOrder;
  ChatMessage(this.id, this.role, this.timestamp, this.dateContext,
      this.originalTimestamp, this.text, this.mediaRefs, this.sourceOrder);
}

class ChatConversation {
  final String id;
  final String title;
  final String sourceFile;
  final List<ChatMessage> allMessages;
  final Map<String, List<ChatMessage>> branches;
  final String? activeBranch;
  final List<String> warnings;
  final bool isTree;

  ChatConversation(this.id, this.title, this.sourceFile, this.allMessages,
      this.branches, this.activeBranch, this.warnings, this.isTree);

  int get approximateMessageCount => allMessages.length;
  DateTime? get firstMessageAt =>
      _datedMessages.isEmpty ? null : _datedMessages.first.dateContext;
  DateTime? get lastMessageAt =>
      _datedMessages.isEmpty ? null : _datedMessages.last.dateContext;
  List<ChatMessage> get _datedMessages => [
        ...allMessages.where((m) => m.timestamp != null)
      ]..sort((a, b) => a.timestamp!.compareTo(b.timestamp!));

  /// Branch selection is mandatory if the tree has several leaves and no
  /// valid current_node. Even a valid current_node is visible for review.
  List<ChatMessage> messagesForBranch(String? branchId) {
    if (!isTree) return allMessages;
    if (branches.isEmpty) {
      throw ChatExportException('No complete message branch in $title.');
    }
    final chosen = branchId ?? activeBranch;
    if (chosen == null || !branches.containsKey(chosen)) {
      throw ChatExportException(
          'Choose a branch for $title before extraction.');
    }
    return branches[chosen]!;
  }

  static ChatConversation fromExport(Map raw, String file, int index) {
    final id = _nonempty(raw['id']) ??
        _nonempty(raw['conversation_id']) ??
        '$file#$index';
    final title = _nonempty(raw['title']) ?? 'Untitled conversation';
    final warnings = <String>[];
    if (raw['messages'] is List) {
      final messages = <ChatMessage>[];
      final seen = <String>{};
      for (var i = 0; i < (raw['messages'] as List).length; i++) {
        final item = (raw['messages'] as List)[i];
        if (item is! Map) continue;
        final message = _parseMessage(item, i);
        if (message != null && seen.add(message.id)) messages.add(message);
      }
      messages.sort(_chronological);
      return ChatConversation(
          id, title, file, messages, const {}, null, warnings, false);
    }
    final mapping = raw['mapping'] as Map;
    final nodes = <String, Map>{};
    for (final entry in mapping.entries) {
      if (entry.value is Map) nodes['${entry.key}'] = entry.value as Map;
    }
    final messagesByNode = <String, ChatMessage>{};
    var order = 0;
    for (final entry in nodes.entries) {
      final rawMessage = entry.value['message'];
      if (rawMessage is Map) {
        final message =
            _parseMessage(rawMessage, order++, fallbackId: entry.key);
        if (message != null) messagesByNode[entry.key] = message;
      }
    }
    final parents = <String, String?>{};
    final parentIds = <String>{};
    for (final entry in nodes.entries) {
      final parent = _nonempty(entry.value['parent']);
      parents[entry.key] = parent;
      if (parent != null && nodes.containsKey(parent)) parentIds.add(parent);
    }
    final leaves = nodes.keys.where((key) => !parentIds.contains(key)).toList()
      ..sort();
    final branches = <String, List<ChatMessage>>{};
    for (final leaf in leaves) {
      final path = <ChatMessage>[];
      final visited = <String>{};
      String? cursor = leaf;
      while (cursor != null && nodes.containsKey(cursor)) {
        if (!visited.add(cursor)) {
          warnings.add('Cycle in message tree near $cursor; branch omitted.');
          path.clear();
          break;
        }
        final message = messagesByNode[cursor];
        if (message != null) path.add(message);
        final parent = parents[cursor];
        if (parent != null && !nodes.containsKey(parent)) {
          warnings.add('Missing parent $parent for $cursor; branch omitted.');
          path.clear();
          break;
        }
        cursor = parent;
      }
      if (path.isNotEmpty) branches[leaf] = path.reversed.toList();
    }
    final active = _nonempty(raw['current_node']);
    final activeBranch = active != null && branches.containsKey(active)
        ? active
        : branches.length == 1
            ? branches.keys.single
            : null;
    if (branches.length > 1) {
      warnings.add(activeBranch == null
          ? 'Multiple branches; select one explicitly.'
          : 'Multiple branches; current branch $activeBranch selected.');
    }
    if (active != null && !branches.containsKey(active)) {
      warnings.add('current_node $active was not a usable leaf.');
    }
    final uniqueMessages = <String, ChatMessage>{};
    for (final message in messagesByNode.values) {
      uniqueMessages.putIfAbsent(message.id, () => message);
    }
    final all = uniqueMessages.values.toList()..sort(_chronological);
    return ChatConversation(
        id, title, file, all, branches, activeBranch, warnings, true);
  }
}

int _chronological(ChatMessage a, ChatMessage b) {
  if (a.timestamp != null && b.timestamp != null) {
    final byTime = a.timestamp!.compareTo(b.timestamp!);
    if (byTime != 0) return byTime;
  }
  return a.sourceOrder.compareTo(b.sourceOrder);
}

ChatMessage? _parseMessage(Map raw, int order, {String? fallbackId}) {
  final role = raw['author'] is Map
      ? '${(raw['author'] as Map)['role'] ?? ''}'
      : '${raw['role'] ?? ''}';
  if (role != 'user' && role != 'assistant') return null;
  final id = _nonempty(raw['id']) ?? fallbackId ?? 'message-$order';
  final sourceTimestamp = raw['create_time'] ?? raw['timestamp'];
  final timestamp = _parseTimestamp(sourceTimestamp);
  final dateContext = sourceTimestamp is String
      ? _wallTimeFromTimestamp(sourceTimestamp) ?? timestamp?.toLocal()
      : timestamp?.toLocal();
  final content = raw['content'] ?? raw['text'];
  final parts = content is Map ? content['parts'] : content;
  final textParts = <String>[];
  final media = <String>[];
  void collect(Object? value) {
    if (value is String) {
      textParts.add(value);
    } else if (value is List) {
      for (final item in value) {
        collect(item);
      }
    } else if (value is Map) {
      if (value['text'] is String) textParts.add(value['text'] as String);
      if (value['content'] is String) textParts.add(value['content'] as String);
      for (final key in ['asset_pointer', 'file_id', 'image', 'filename']) {
        if (value[key] is String) media.add('$key:${value[key]}');
      }
    }
  }

  collect(parts);
  if (textParts.isEmpty && content is Map) collect(content);
  return ChatMessage(id, role, timestamp, dateContext,
      sourceTimestamp?.toString(), textParts.join('\n').trim(), media, order);
}

String? _nonempty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

DateTime? _parseTimestamp(Object? value) {
  if (value is num && value.isFinite) {
    final milliseconds =
        value.abs() >= 100000000000 ? value.round() : (value * 1000).round();
    try {
      return DateTime.fromMillisecondsSinceEpoch(milliseconds);
    } catch (_) {
      return null;
    }
  }
  if (value is String) return DateTime.tryParse(value)?.toLocal();
  return null;
}

DateTime? _wallTimeFromTimestamp(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?')
      .firstMatch(value);
  if (match == null) return null;
  final parts =
      List.generate(6, (index) => int.parse(match.group(index + 1) ?? '0'));
  final date =
      DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
  if (date.year != parts[0] ||
      date.month != parts[1] ||
      date.day != parts[2] ||
      date.hour != parts[3] ||
      date.minute != parts[4]) {
    return null;
  }
  return date;
}
