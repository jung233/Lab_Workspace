import 'security.dart';

final class CommandMetadata {
  const CommandMetadata({
    required this.commandId,
    required this.utcTime,
    this.baseRevision,
    this.actor = 'local_user',
    this.sourceRef,
    this.approvalRef,
  }) : assert(commandId != ''),
       assert(actor != '');

  final String commandId;
  final int? baseRevision;
  final DateTime utcTime;
  final String actor;
  final String? sourceRef;
  final ApprovalRef? approvalRef;

  DateTime get normalizedUtcTime => utcTime.toUtc();
}
