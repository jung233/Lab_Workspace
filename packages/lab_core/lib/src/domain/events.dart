import 'dart:convert';

import 'commands.dart';
import 'ids.dart';

final class MutationEventDraft {
  const MutationEventDraft({
    required this.command,
    required this.deviceId,
    required this.entityType,
    required this.entityId,
    required this.eventType,
    required this.action,
    required this.payloadJson,
    this.assetShaRefs = const [],
  });

  final CommandMetadata command;
  final DeviceId deviceId;
  final String entityType;
  final String entityId;
  final String eventType;
  final MutationAction action;
  final String payloadJson;
  final List<String> assetShaRefs;

  Map<String, Object?> get payload {
    final value = jsonDecode(payloadJson);
    if (value is! Map<String, Object?>) {
      throw const FormatException('Mutation payload must be a JSON object.');
    }
    return value;
  }
}

enum MutationAction {
  create,
  patch,
  append,
  tombstone,
  resolve;

  String get wireValue => name;
}

final class MutationEvent {
  const MutationEvent({
    required this.eventId,
    required this.commandId,
    required this.deviceId,
    required this.sequence,
    required this.lamport,
    required this.entityType,
    required this.entityId,
    required this.baseRevision,
    required this.eventType,
    required this.action,
    required this.payloadJson,
    required this.assetShaRefs,
    required this.createdAtUtc,
  });

  final MutationId eventId;
  final CommandId commandId;
  final DeviceId deviceId;
  final int sequence;
  final int lamport;
  final String entityType;
  final String entityId;
  final int? baseRevision;
  final String eventType;
  final MutationAction action;
  final String payloadJson;
  final List<String> assetShaRefs;
  final DateTime createdAtUtc;

  Map<String, Object?> get payload {
    final value = jsonDecode(payloadJson);
    if (value is! Map<String, Object?>) {
      throw const FormatException('Mutation payload must be a JSON object.');
    }
    return value;
  }

  Map<String, Object?> toSyncDocument(VaultId vaultId) => {
    'schema_version': '3.0',
    'vault_id': vaultId,
    'device_id': deviceId,
    'seq': sequence,
    'lamport': lamport,
    'event_id': eventId,
    'command_id': commandId,
    'entity_kind': entityType,
    'entity_id': entityId,
    'base_revision': baseRevision,
    'event_type': eventType,
    'action': action.wireValue,
    'payload': jsonDecode(payloadJson),
    'sha_refs': assetShaRefs,
    'created_at_utc': createdAtUtc.toUtc().toIso8601String(),
  };
}
