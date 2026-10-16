sealed class LabWorkspaceException implements Exception {
  const LabWorkspaceException(this.code, this.message, {this.details = const {}});

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => '$code: $message';
}

final class ValidationException extends LabWorkspaceException {
  const ValidationException(
    super.code,
    super.message, {
    super.details,
  });
}

final class RevisionConflictException extends LabWorkspaceException {
  RevisionConflictException({
    required String entityType,
    required String entityId,
    required int expectedRevision,
    required int actualRevision,
  }) : super(
         'REVISION_CONFLICT',
         'The $entityType changed since it was loaded.',
         details: {
           'entity_type': entityType,
           'entity_id': entityId,
           'expected_revision': expectedRevision,
           'actual_revision': actualRevision,
         },
       );
}

final class MissingEntityException extends LabWorkspaceException {
  MissingEntityException(String entityType, String entityId)
    : super(
        'ENTITY_NOT_FOUND',
        '$entityType $entityId was not found.',
        details: {'entity_type': entityType, 'entity_id': entityId},
      );
}

final class UnsupportedSchemaVersionException extends LabWorkspaceException {
  UnsupportedSchemaVersionException(int actual, int supported)
    : super(
        'SCHEMA_VERSION_UNSUPPORTED',
        'Database schema $actual is newer than supported schema $supported.',
        details: {'actual': actual, 'supported': supported},
      );
}

final class CommandAlreadyAppliedException extends LabWorkspaceException {
  CommandAlreadyAppliedException(String commandId)
    : super(
        'COMMAND_ALREADY_APPLIED',
        'Command $commandId was already applied.',
        details: {'command_id': commandId},
      );
}
