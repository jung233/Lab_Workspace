import 'json_value.dart';

final class ProjectRecord {
  const ProjectRecord({
    required this.projectId,
    required this.title,
    required this.note,
    required this.revision,
    required this.createdAtUtc,
    this.deletedAtUtc,
  });

  final String projectId;
  final String title;
  final String note;
  final int revision;
  final DateTime createdAtUtc;
  final DateTime? deletedAtUtc;
  bool get isDeleted => deletedAtUtc != null;
}

final class ExperimentRecord {
  const ExperimentRecord({
    required this.experimentId,
    required this.projectId,
    required this.title,
    required this.note,
    required this.revision,
    required this.createdAtUtc,
    this.deletedAtUtc,
  });

  final String experimentId;
  final String? projectId;
  final String title;
  final String note;
  final int revision;
  final DateTime createdAtUtc;
  final DateTime? deletedAtUtc;
  bool get isDeleted => deletedAtUtc != null;
}

final class ProtocolVersionRecord {
  ProtocolVersionRecord({
    required this.protocolId,
    required this.version,
    required this.title,
    required this.status,
    required Map<String, Object?> document,
    required this.payloadSha256,
    required this.createdAtUtc,
    this.approvalRef,
    this.approvedAtUtc,
  }) : document = freezeJsonObject(document);

  final String protocolId;
  final String version;
  final String title;
  final String status;
  final Map<String, Object?> document;
  final String payloadSha256;
  final DateTime createdAtUtc;
  final String? approvalRef;
  final DateTime? approvedAtUtc;
  bool get isApproved => status == 'approved' && approvedAtUtc != null;
}

final class ProtocolSummaryRecord {
  const ProtocolSummaryRecord({
    required this.protocolId,
    required this.title,
    required this.currentVersion,
  });

  final String protocolId;
  final String title;
  final String? currentVersion;
}

final class RunRecord {
  RunRecord({
    required this.runId,
    required this.experimentId,
    required this.protocolId,
    required this.protocolVersion,
    required this.title,
    required this.state,
    required this.revision,
    required Map<String, Object?> parameterSnapshot,
    required Map<String, Object?> protocolSnapshot,
    required this.createdAtUtc,
    this.plannedStartUtc,
    this.startedAtUtc,
    this.finishedAtUtc,
  }) : parameterSnapshot = freezeJsonObject(parameterSnapshot),
       protocolSnapshot = freezeJsonObject(protocolSnapshot);

  final String runId;
  final String? experimentId;
  final String? protocolId;
  final String? protocolVersion;
  final String title;
  final String state;
  final int revision;
  final Map<String, Object?> parameterSnapshot;
  final Map<String, Object?> protocolSnapshot;
  final DateTime createdAtUtc;
  final DateTime? plannedStartUtc;
  final DateTime? startedAtUtc;
  final DateTime? finishedAtUtc;
}

final class StepRecord {
  StepRecord({
    required this.stepId,
    required this.runId,
    required this.protocolStepId,
    required this.kind,
    required this.title,
    required this.state,
    required this.plannedStartUtc,
    required this.plannedEndUtc,
    required this.startedAtUtc,
    required this.dueAtUtc,
    required this.completedAtUtc,
    required this.expectedSeconds,
    required this.durationMinSeconds,
    required this.durationMaxSeconds,
    required this.durationOrigin,
    required this.revision,
    required Map<String, Object?> captured,
    required Map<String, Object?> parameters,
    required this.humanGate,
    required this.repeatIndex,
    required this.resourceKey,
    required this.instructions,
    required List<String> dependencies,
  }) : captured = freezeJsonObject(captured),
       parameters = freezeJsonObject(parameters),
       dependencies = List.unmodifiable(dependencies);

  final String stepId;
  final String runId;
  final String? protocolStepId;
  final String kind;
  final String title;
  final String state;
  final DateTime? plannedStartUtc;
  final DateTime? plannedEndUtc;
  final DateTime? startedAtUtc;
  final DateTime? dueAtUtc;
  final DateTime? completedAtUtc;
  final int? expectedSeconds;
  final int? durationMinSeconds;
  final int? durationMaxSeconds;
  final String durationOrigin;
  final int revision;
  final Map<String, Object?> captured;
  final Map<String, Object?> parameters;
  final bool humanGate;
  final int repeatIndex;
  final String? resourceKey;
  final String instructions;
  final List<String> dependencies;
}

final class SampleRecord {
  SampleRecord({
    required this.sampleId,
    required this.name,
    required this.parentSampleId,
    required Map<String, Object?> properties,
    required this.revision,
    required this.createdAtUtc,
    this.deletedAtUtc,
  }) : properties = freezeJsonObject(properties);

  final String sampleId;
  final String name;
  final String? parentSampleId;
  final Map<String, Object?> properties;
  final int revision;
  final DateTime createdAtUtc;
  final DateTime? deletedAtUtc;
}

final class ExperimentalGroupRecord {
  ExperimentalGroupRecord({
    required this.groupId,
    required this.runId,
    required this.title,
    required Map<String, Object?> conditions,
    required this.revision,
  }) : conditions = freezeJsonObject(conditions);

  final String groupId;
  final String runId;
  final String title;
  final Map<String, Object?> conditions;
  final int revision;
}

final class TreatmentRecord {
  TreatmentRecord({
    required this.treatmentId,
    required this.sampleId,
    required this.runId,
    required Map<String, Object?> conditions,
    required this.appliedAtUtc,
    required this.correctedFrom,
    required this.recordedAtUtc,
  }) : conditions = freezeJsonObject(conditions);

  final String treatmentId;
  final String sampleId;
  final String runId;
  final Map<String, Object?> conditions;
  final DateTime? appliedAtUtc;
  final String? correctedFrom;
  final DateTime recordedAtUtc;
}

final class MeasurementRecord {
  const MeasurementRecord({
    required this.measurementId,
    required this.runId,
    required this.stepId,
    required this.sampleId,
    required this.analyte,
    required this.valueText,
    required this.unit,
    required this.rawAssetId,
    required this.state,
    required this.supersededBy,
    required this.sourceMethod,
    required this.sourceRef,
    required this.calculationId,
    this.remoteCalculationId,
    this.remoteCalculationOutputKey,
    this.remoteSourceEventId,
    this.remoteMeasurementId,
    required this.createdAtUtc,
    required this.confirmedAtUtc,
    required this.revision,
  });

  final String measurementId;
  final String runId;
  final String? stepId;
  final String? sampleId;
  final String analyte;
  final String valueText;
  final String? unit;
  final String? rawAssetId;
  final String state;
  final String? supersededBy;
  final String? sourceMethod;
  final String? sourceRef;
  final String? calculationId;
  final String? remoteCalculationId;
  final String? remoteCalculationOutputKey;
  final String? remoteSourceEventId;
  final String? remoteMeasurementId;
  final DateTime createdAtUtc;
  final DateTime? confirmedAtUtc;
  final int revision;
}

final class RemoteMeasurementImportRecord {
  RemoteMeasurementImportRecord({
    required this.sourceEventId,
    required this.measurementId,
    required this.sourceEventType,
    required this.sourceDeviceId,
    required this.calculationId,
    required this.calculationTraceSha256,
    required Map<String, Object?> payload,
    required List<String> assetShaRefs,
    required this.importedAtUtc,
    required this.reviewState,
    this.localMeasurementId,
    this.approvalRef,
    this.reviewedAtUtc,
    this.reviewReason,
  }) : payload = freezeJsonObject(payload),
       assetShaRefs = List.unmodifiable(assetShaRefs);

  final String sourceEventId;
  final String measurementId;
  final String sourceEventType;
  final String sourceDeviceId;
  final String calculationId;
  final String calculationTraceSha256;
  final Map<String, Object?> payload;
  final List<String> assetShaRefs;
  final DateTime importedAtUtc;
  final String reviewState;
  final String? localMeasurementId;
  final String? approvalRef;
  final DateTime? reviewedAtUtc;
  final String? reviewReason;
}

final class ScheduledStep {
  const ScheduledStep({
    required this.stepId,
    required this.runId,
    required this.runTitle,
    required this.title,
    required this.state,
    required this.plannedStartUtc,
    required this.plannedEndUtc,
    required this.dueAtUtc,
    required this.expectedSeconds,
    required this.durationOrigin,
    required this.humanGate,
  });

  final String stepId;
  final String runId;
  final String runTitle;
  final String title;
  final String state;
  final DateTime? plannedStartUtc;
  final DateTime? plannedEndUtc;
  final DateTime? dueAtUtc;
  final int? expectedSeconds;
  final String durationOrigin;
  final bool humanGate;
}

final class SchedulePlan {
  SchedulePlan({
    required this.traceId,
    required this.runId,
    required this.generation,
    required this.startAtUtc,
    required List<ScheduledStep> steps,
    required List<String> warnings,
  }) : steps = List.unmodifiable(steps),
       warnings = List.unmodifiable(warnings);

  final String traceId;
  final String runId;
  final int generation;
  final DateTime startAtUtc;
  final List<ScheduledStep> steps;
  final List<String> warnings;
}

final class TaskRecord {
  const TaskRecord({
    required this.taskId,
    required this.stepId,
    required this.title,
    required this.dueAtUtc,
    required this.state,
    required this.revision,
    required this.createdAtUtc,
    this.completedAtUtc,
    this.deletedAtUtc,
  });

  final String taskId;
  final String? stepId;
  final String title;
  final DateTime? dueAtUtc;
  final String state;
  final int revision;
  final DateTime createdAtUtc;
  final DateTime? completedAtUtc;
  final DateTime? deletedAtUtc;
}

final class ReminderRecord {
  const ReminderRecord({
    required this.reminderId,
    required this.taskId,
    required this.stepId,
    required this.dueAtUtc,
    required this.minutesBefore,
    required this.permissionState,
    required this.deliveryState,
    required this.status,
    required this.lastAttemptAtUtc,
  });

  final String reminderId;
  final String? taskId;
  final String? stepId;
  final DateTime dueAtUtc;
  final int minutesBefore;
  final String? permissionState;
  final String deliveryState;
  final String status;
  final DateTime? lastAttemptAtUtc;
  DateTime get fireAtUtc => dueAtUtc.subtract(Duration(minutes: minutesBefore));
}

final class DashboardSnapshot {
  DashboardSnapshot({
    required this.activeProjectCount,
    required this.activeExperimentCount,
    required this.activeRunCount,
    required this.openTaskCount,
    required List<RunRecord> recentRuns,
    required List<ScheduledStep> upcomingSteps,
    required this.generatedAtUtc,
  }) : recentRuns = List.unmodifiable(recentRuns),
       upcomingSteps = List.unmodifiable(upcomingSteps);

  final int activeProjectCount;
  final int activeExperimentCount;
  final int activeRunCount;
  final int openTaskCount;
  final List<RunRecord> recentRuns;
  final List<ScheduledStep> upcomingSteps;
  final DateTime generatedAtUtc;
}
