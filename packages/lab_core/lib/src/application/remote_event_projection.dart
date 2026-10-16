import '../domain/events.dart';
import '../domain/json_value.dart';
import '../persistence/workspace_database.dart';

/// Immutable, validated context for an event received from another device.
/// The sync wire format intentionally has no executable event type or command
/// identifier; projections derive safe behavior from entity, action, and data.
final class RemoteEventEnvelope {
  RemoteEventEnvelope({
    required this.eventId,
    required this.targetId,
    required this.deviceId,
    required this.sequence,
    required this.lamport,
    required this.entityType,
    required this.entityId,
    required this.baseRevision,
    required this.action,
    required Map<String, Object?> payload,
    required List<String> assetShaRefs,
    required this.occurredAtUtc,
  }) : payload = freezeJsonObject(payload),
       assetShaRefs = List<String>.unmodifiable(assetShaRefs);

  final String eventId;
  final String targetId;
  final String deviceId;
  final int sequence;
  final int lamport;
  final String entityType;
  final String entityId;
  final int? baseRevision;
  final MutationAction action;
  final Map<String, Object?> payload;
  final List<String> assetShaRefs;
  final DateTime occurredAtUtc;
}

/// A domain-owned projection adapter. Implementations may only use explicit
/// typed validation and transaction methods; payload text is never SQL/code.
abstract interface class RemoteEventProjectionHandler {
  bool canHandle({
    required String entityType,
    required MutationAction action,
    required Map<String, Object?> payload,
  });

  void apply(WorkspaceTransaction tx, RemoteEventEnvelope event);
}

final class RemoteProjectionBlocked implements Exception {
  const RemoteProjectionBlocked(this.code, this.message);

  final String code;
  final String message;
}

final class RemoteProjectionConflict implements Exception {
  const RemoteProjectionConflict(
    this.code,
    this.message, {
    this.counterpartEventId,
  });

  final String code;
  final String message;
  final String? counterpartEventId;
}
