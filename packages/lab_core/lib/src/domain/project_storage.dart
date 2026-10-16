/// Local, per-device state for the human-browsable project directory.
///
/// These locations are deliberately not part of synchronized Project records:
/// an absolute path and an exported copy belong to one device only.
enum ProjectStorageManifestStatus {
  notGenerated,
  ready,
  missing,
  externallyChanged,
  blocked;

  String get wireValue => switch (this) {
    ProjectStorageManifestStatus.notGenerated => 'not_generated',
    ProjectStorageManifestStatus.externallyChanged => 'externally_changed',
    _ => name,
  };
}

final class ProjectStorageLocation {
  const ProjectStorageLocation({
    required this.projectId,
    required this.rootDirectory,
    required this.isDefault,
    required this.directoryExists,
    required this.manifestStatus,
    this.lastGeneratedAtUtc,
  });

  final String projectId;
  final String rootDirectory;
  final bool isDefault;
  final bool directoryExists;
  final ProjectStorageManifestStatus manifestStatus;
  final DateTime? lastGeneratedAtUtc;
}

final class ProjectStorageState {
  const ProjectStorageState({
    required this.location,
    required this.linkedAssetCount,
    required this.copiedFileCount,
    required this.externalChangedFileCount,
    required this.unlinkedRetainedFileCount,
    required this.missingOrFailedFileCount,
  });

  final ProjectStorageLocation location;
  final int linkedAssetCount;
  final int copiedFileCount;
  final int externalChangedFileCount;
  final int unlinkedRetainedFileCount;
  final int missingOrFailedFileCount;

  bool get needsGeneration =>
      linkedAssetCount > copiedFileCount ||
      externalChangedFileCount > 0 ||
      missingOrFailedFileCount > 0 ||
      location.manifestStatus != ProjectStorageManifestStatus.ready;
}

final class ProjectStorageIssue {
  const ProjectStorageIssue({
    required this.assetId,
    required this.displayName,
    required this.state,
    required this.message,
  });

  final String assetId;
  final String displayName;
  final String state;
  final String message;
}

final class ProjectStorageBuildReport {
  ProjectStorageBuildReport({
    required this.projectId,
    required this.rootDirectory,
    required this.totalAssetCount,
    required this.copiedAssetCount,
    required this.alreadyPresentAssetCount,
    required this.externalChangedAssetCount,
    required this.missingAssetCount,
    required this.failedAssetCount,
    required this.manifestUpdated,
    required this.manifestConflict,
    required List<ProjectStorageIssue> issues,
  }) : issues = List.unmodifiable(issues);

  final String projectId;
  final String rootDirectory;
  final int totalAssetCount;
  final int copiedAssetCount;
  final int alreadyPresentAssetCount;
  final int externalChangedAssetCount;
  final int missingAssetCount;
  final int failedAssetCount;
  final bool manifestUpdated;
  final bool manifestConflict;
  final List<ProjectStorageIssue> issues;
}
