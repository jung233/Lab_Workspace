import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../assets/asset_gateway.dart';
import '../assets/asset_models.dart';
import '../domain/project_storage.dart';
import '../domain/vault.dart';
import '../persistence/workspace_database.dart';

/// Owns a device-local, human-browsable copy of the Assets linked to a project.
/// The Vault CAS remains the only authoritative source; every exported file is
/// copied through AssetGateway's leased, full-SHA snapshot API.
final class ProjectStorageService {
  ProjectStorageService({
    required VaultContext vault,
    required AssetGateway assets,
    required String documentsDirectory,
  }) : _vault = vault,
       _assets = assets,
       _defaultParentDirectory = p.join(
         documentsDirectory,
         'Lab Workspace',
         '项目',
       );

  static const String manifestFileName = '项目清单.json';
  static const List<String> categoryDirectories = <String>[
    '原始文件',
    '实验记录',
    '分析结果',
    '导出',
  ];

  final VaultContext _vault;
  final AssetGateway _assets;
  final String _defaultParentDirectory;
  WorkspaceDatabase get _database => _vault.database;

  /// Returns and persists the current device's root, using Documents as the
  /// default parent. It may reconcile the owned manifest for removed links,
  /// but it never creates browse copies or removes user-visible files.
  Future<ProjectStorageState> describe(String projectId) async {
    final project = _requireProject(projectId);
    var locationRow = _activeLocationRow(projectId);
    if (locationRow != null && locationRow['device_id'] != _vault.deviceId) {
      _database.execute(
        'UPDATE project_storage_locations SET is_active=0,updated_at_utc=? '
        'WHERE project_id=? AND device_id=? AND root_directory=? AND is_active=1',
        <Object?>[
          DateTime.now().toUtc().toIso8601String(),
          projectId,
          locationRow['device_id'],
          locationRow['root_directory'],
        ],
      );
      locationRow = null;
    }
    locationRow ??= await _activateLocation(
      projectId: projectId,
      projectTitle: _string(project['title']),
      parentDirectory: _defaultParentDirectory,
      isDefault: true,
      requireExistingParent: false,
    );

    final root = _string(locationRow['root_directory']);
    await _validateRoot(root, projectId: projectId);
    final entityType = await FileSystemEntity.type(root, followLinks: false);
    final projectAssets = _projectAssetRows(projectId);
    final currentAssetIds = projectAssets
        .map((row) => _string(row['asset_id']))
        .toSet();
    final unlinkedChanged = _markUnlinkedRetainedFiles(
      projectId: projectId,
      rootDirectory: root,
      currentAssetIds: currentAssetIds,
    );
    if (unlinkedChanged &&
        entityType == FileSystemEntityType.directory &&
        _manifestStatus(_string(locationRow['manifest_status'])) ==
            ProjectStorageManifestStatus.ready &&
        await FileSystemEntity.type(
              p.join(root, manifestFileName),
              followLinks: false,
            ) ==
            FileSystemEntityType.file) {
      await _writeManifest(projectId, root, _string(project['title']));
      locationRow = _locationRow(projectId, root) ?? locationRow;
    }
    final files = _database.query(
      '''SELECT state,COUNT(*) AS file_count FROM project_storage_files
         WHERE project_id=? AND device_id=? AND root_directory=? GROUP BY state''',
      <Object?>[projectId, _vault.deviceId, root],
    );
    final counts = <String, int>{
      for (final row in files) _string(row['state']): _int(row['file_count']),
    };
    final linkedAssetCount = projectAssets
        .where((row) => row['deleted_at_utc'] == null)
        .length;
    final manifestStatus = _manifestStatus(
      _string(locationRow['manifest_status']),
    );
    return ProjectStorageState(
      location: ProjectStorageLocation(
        projectId: projectId,
        rootDirectory: root,
        isDefault: _int(locationRow['is_default']) == 1,
        directoryExists: entityType == FileSystemEntityType.directory,
        manifestStatus: manifestStatus,
        lastGeneratedAtUtc: _dateTime(locationRow['last_generated_at_utc']),
      ),
      linkedAssetCount: linkedAssetCount,
      copiedFileCount: counts['copied'] ?? 0,
      externalChangedFileCount: counts['externally_changed'] ?? 0,
      unlinkedRetainedFileCount: counts['unlinked_retained'] ?? 0,
      missingOrFailedFileCount:
          (counts['missing'] ?? 0) +
          (counts['source_missing'] ?? 0) +
          (counts['failed'] ?? 0) +
          (counts['conflict'] ?? 0),
    );
  }

  /// Selects a parent folder. The service appends its stable ID/readable-name
  /// child, validates it, and records it without copying or deleting anything.
  Future<ProjectStorageState> setCustomParentDirectory(
    String projectId,
    String parentDirectory,
  ) async {
    final project = _requireProject(projectId);
    await _activateLocation(
      projectId: projectId,
      projectTitle: _string(project['title']),
      parentDirectory: parentDirectory,
      isDefault: false,
      requireExistingParent: true,
    );
    return describe(projectId);
  }

  Future<ProjectStorageState> useDefaultDirectory(String projectId) async {
    final project = _requireProject(projectId);
    await _activateLocation(
      projectId: projectId,
      projectTitle: _string(project['title']),
      parentDirectory: _defaultParentDirectory,
      isDefault: true,
      requireExistingParent: false,
    );
    return describe(projectId);
  }

  /// Explicitly creates/updates the project directory from linked Assets.
  /// Existing browse copies are SHA-checked; externally changed and unknown
  /// files are preserved and reported rather than overwritten.
  Future<ProjectStorageBuildReport> generateDirectory(String projectId) async {
    final project = _requireProject(projectId);
    final location = (await describe(projectId)).location;
    final root = location.rootDirectory;
    await _validateRoot(root, projectId: projectId);
    final rootType = await FileSystemEntity.type(root, followLinks: false);
    if (rootType == FileSystemEntityType.link) {
      throw StateError('项目目录是符号链接，已拒绝写入。');
    }
    if (rootType == FileSystemEntityType.file) {
      throw StateError('项目目录路径已被同名文件占用。');
    }
    if (rootType == FileSystemEntityType.notFound) {
      await Directory(root).create(recursive: true);
    }

    var locationRow = _locationRow(projectId, root);
    if (locationRow == null) throw StateError('项目目录配置已改变，请刷新后重试。');
    final manifestFile = File(p.join(root, manifestFileName));
    final manifestType = await FileSystemEntity.type(
      manifestFile.path,
      followLinks: false,
    );
    if (manifestType == FileSystemEntityType.link ||
        manifestType == FileSystemEntityType.directory) {
      _setManifestStatus(projectId, root, 'blocked');
      throw StateError('项目清单路径被符号链接或目录占用，已拒绝覆盖。');
    }

    if (manifestType == FileSystemEntityType.file) {
      final actualManifestSha = await _hashFile(manifestFile);
      final pendingSha = _nullableString(
        locationRow['pending_manifest_sha256'],
      );
      final publishedSha = _nullableString(locationRow['manifest_sha256']);
      if (pendingSha != null && actualManifestSha == pendingSha) {
        _finishManifestWrite(projectId, root, pendingSha);
      } else if (publishedSha != null && actualManifestSha == publishedSha) {
        _setManifestStatus(projectId, root, 'ready');
      } else {
        _setManifestStatus(projectId, root, 'externally_changed');
        throw StateError('项目清单已由外部修改或不属于此项目，未覆盖；请先另选目录或人工保留并移走该清单。');
      }
    } else {
      final knownManifestSha =
          _nullableString(locationRow['manifest_sha256']) ??
          _nullableString(locationRow['pending_manifest_sha256']);
      if (knownManifestSha == null) {
        final entries = await Directory(root).list(followLinks: false).toList();
        if (entries.isNotEmpty) {
          _setManifestStatus(projectId, root, 'blocked');
          throw StateError('所选项目目录已包含未受管文件且没有本项目清单；为避免接管或覆盖既有内容，请选择空目录。');
        }
      }
      // A first, empty manifest makes an interrupted initial copy resumable.
      await _writeManifest(projectId, root, _string(project['title']));
    }

    await _createLayoutDirectories(root);
    final assets = _projectAssetRows(projectId);
    var copied = 0;
    var alreadyPresent = 0;
    var externallyChanged = 0;
    var missing = 0;
    var failed = 0;
    final issues = <ProjectStorageIssue>[];

    for (final asset in assets) {
      final result = await _materializeAsset(
        projectId: projectId,
        rootDirectory: root,
        asset: asset,
      );
      switch (result.state) {
        case 'copied':
          copied++;
          break;
        case 'already_present':
          alreadyPresent++;
          break;
        case 'externally_changed':
          externallyChanged++;
          issues.add(result.issue!);
          break;
        case 'missing':
          missing++;
          issues.add(result.issue!);
          break;
        case 'failed':
        case 'conflict':
        case 'source_missing':
          failed++;
          issues.add(result.issue!);
          break;
        case 'soft_deleted':
          break;
        default:
          failed++;
          issues.add(
            result.issue ??
                ProjectStorageIssue(
                  assetId: _string(asset['asset_id']),
                  displayName: _string(asset['display_name']),
                  state: result.state,
                  message: '未识别的项目副本状态。',
                ),
          );
      }
    }

    final manifestUpdated = await _writeManifest(
      projectId,
      root,
      _string(project['title']),
    );
    final locationAfter = _locationRow(projectId, root);
    final manifestStatus = _string(locationAfter?['manifest_status']);
    final manifestConflict =
        manifestStatus == 'externally_changed' ||
        manifestStatus == 'blocked' ||
        _nullableString(locationAfter?['manifest_sha256']) == null;
    final generatedAt = DateTime.now().toUtc().toIso8601String();
    _database.execute(
      '''UPDATE project_storage_locations SET last_generated_at_utc=?,updated_at_utc=?
         WHERE project_id=? AND device_id=? AND root_directory=?''',
      <Object?>[generatedAt, generatedAt, projectId, _vault.deviceId, root],
    );
    return ProjectStorageBuildReport(
      projectId: projectId,
      rootDirectory: root,
      totalAssetCount: assets
          .where((row) => row['deleted_at_utc'] == null)
          .length,
      copiedAssetCount: copied,
      alreadyPresentAssetCount: alreadyPresent,
      externalChangedAssetCount: externallyChanged,
      missingAssetCount: missing,
      failedAssetCount: failed,
      manifestUpdated: manifestUpdated,
      manifestConflict: manifestConflict,
      issues: issues,
    );
  }

  /// Creates verified browse copies after a locally committed import. Project
  /// association is read from AssetLink and ancestor AssetLink records, so the
  /// physical location stays local and is never written to a sync event.
  Future<void> materializeImportedAsset(
    AssetRecord asset, {
    required AssetId? parentAssetId,
    required List<AssetLinkRef> links,
  }) async {
    final projectIds = _projectIdsForAsset(asset.assetId);
    for (final projectId in projectIds) {
      try {
        final state = await describe(projectId);
        final location = state.location;
        if (location.manifestStatus == ProjectStorageManifestStatus.ready &&
            location.directoryExists) {
          final project = _requireProject(projectId);
          final root = location.rootDirectory;
          await _validateRoot(root, projectId: projectId);
          final manifestType = await FileSystemEntity.type(
            p.join(root, manifestFileName),
            followLinks: false,
          );
          if (manifestType == FileSystemEntityType.notFound) {
            await generateDirectory(projectId);
            continue;
          }
          await _confirmCurrentManifest(projectId, root);
          await _createLayoutDirectories(root);
          final row = _projectAssetRow(projectId, asset.assetId);
          if (row != null) {
            await _materializeAsset(
              projectId: projectId,
              rootDirectory: root,
              asset: row,
            );
            await _writeManifest(projectId, root, _string(project['title']));
            continue;
          }
        }
        await generateDirectory(projectId);
      } on Object {
        final active = _activeLocationRow(projectId);
        if (active != null &&
            active['device_id'] == _vault.deviceId &&
            active['manifest_status'] != 'externally_changed') {
          _setManifestStatus(
            projectId,
            _string(active['root_directory']),
            'blocked',
          );
        }
        // AssetGateway keeps the import committed. The settings dialog reports
        // the blocked directory; the user can choose another root and retry.
      }
    }
  }

  Future<Map<String, Object?>> _activateLocation({
    required String projectId,
    required String projectTitle,
    required String parentDirectory,
    required bool isDefault,
    required bool requireExistingParent,
  }) async {
    final root = await _rootForParent(
      parentDirectory,
      projectId: projectId,
      projectTitle: projectTitle,
      requireExistingParent: requireExistingParent,
    );
    await _validateRoot(root, projectId: projectId);
    final now = DateTime.now().toUtc().toIso8601String();
    _database.transaction((tx) {
      tx.execute(
        '''UPDATE project_storage_locations SET is_active=0,updated_at_utc=?
           WHERE project_id=? AND is_active=1''',
        <Object?>[now, projectId],
      );
      final existing = tx.query(
        '''SELECT 1 FROM project_storage_locations
           WHERE project_id=? AND device_id=? AND root_directory=?''',
        <Object?>[projectId, _vault.deviceId, root],
      );
      if (existing.isEmpty) {
        tx.execute(
          '''INSERT INTO project_storage_locations
             (project_id,device_id,root_directory,is_active,is_default,manifest_status,updated_at_utc)
             VALUES(?,?,?,1,?,'not_generated',?)''',
          <Object?>[projectId, _vault.deviceId, root, isDefault ? 1 : 0, now],
        );
      } else {
        tx.execute(
          '''UPDATE project_storage_locations
             SET is_active=1,is_default=?,updated_at_utc=?
             WHERE project_id=? AND device_id=? AND root_directory=?''',
          <Object?>[isDefault ? 1 : 0, now, projectId, _vault.deviceId, root],
        );
      }
    });
    final rows = _database.query(
      '''SELECT * FROM project_storage_locations
         WHERE project_id=? AND device_id=? AND root_directory=?''',
      <Object?>[projectId, _vault.deviceId, root],
    );
    return rows.single;
  }

  Future<String> _rootForParent(
    String rawParent, {
    required String projectId,
    required String projectTitle,
    required bool requireExistingParent,
  }) async {
    final parent = rawParent.trim();
    if (parent.isEmpty ||
        !p.isAbsolute(parent) ||
        p.split(parent).contains('..')) {
      throw const FormatException('必须选择绝对目录路径，且路径不能包含“..”。');
    }
    final parentDirectory = Directory(p.normalize(parent));
    final parentType = await FileSystemEntity.type(
      parentDirectory.path,
      followLinks: false,
    );
    if (parentType == FileSystemEntityType.file) {
      throw FileSystemException('所选上级路径是文件，不是目录。', parent);
    }
    if (requireExistingParent && parentType == FileSystemEntityType.notFound) {
      throw FileSystemException('所选上级目录不存在或当前不可访问。', parent);
    }
    if (parentType == FileSystemEntityType.directory ||
        parentType == FileSystemEntityType.link) {
      if (requireExistingParent &&
          await FileSystemEntity.type(parent, followLinks: true) !=
              FileSystemEntityType.directory) {
        throw FileSystemException('所选路径不是目录。', parent);
      }
      final canonicalParent = await parentDirectory.resolveSymbolicLinks();
      if (requireExistingParent &&
          await FileSystemEntity.type(canonicalParent, followLinks: false) !=
              FileSystemEntityType.directory) {
        throw FileSystemException('所选路径不是目录。', parent);
      }
      return p.normalize(
        p.join(canonicalParent, _projectFolderName(projectId, projectTitle)),
      );
    }
    final canonicalParent = await _canonicalizeWithMissingSuffix(parent);
    return p.normalize(
      p.join(canonicalParent, _projectFolderName(projectId, projectTitle)),
    );
  }

  Future<void> _validateRoot(String root, {required String projectId}) async {
    if (root.trim().isEmpty ||
        !p.isAbsolute(root) ||
        p.split(root).contains('..')) {
      throw const FormatException('项目根路径必须是安全的绝对路径。');
    }
    final canonicalRoot = await _canonicalizeWithMissingSuffix(root);
    if (_pathKey(canonicalRoot) != _pathKey(p.normalize(p.absolute(root)))) {
      throw StateError('项目目录或其上级路径包含符号链接，请重新选择物理目录。');
    }
    final vaultRoot = await _canonicalizeWithMissingSuffix(
      _vault.rootDirectory,
    );
    if (_pathsOverlap(canonicalRoot, vaultRoot)) {
      throw StateError('项目浏览目录不能位于 Vault 内部，也不能包含 Vault。');
    }
    final recordedRows = _database.query(
      'SELECT project_id,root_directory FROM project_storage_locations',
    );
    for (final row in recordedRows) {
      final otherPath = _string(row['root_directory']);
      final other = await _canonicalizeWithMissingSuffix(otherPath);
      if (_string(row['project_id']) == projectId &&
          _pathKey(other) == _pathKey(canonicalRoot)) {
        continue;
      }
      if (_pathsOverlap(canonicalRoot, other)) {
        throw StateError('项目目录与现有项目目录重叠，请选择不同位置。');
      }
    }
    final type = await FileSystemEntity.type(root, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw StateError('项目根目录不能是符号链接。');
    }
  }

  Future<String> _canonicalizeWithMissingSuffix(String rawPath) async {
    var current = p.normalize(p.absolute(rawPath));
    final suffix = <String>[];
    while (true) {
      final entityType = await FileSystemEntity.type(
        current,
        followLinks: false,
      );
      if (entityType == FileSystemEntityType.link) {
        final resolved = await Directory(current).resolveSymbolicLinks();
        return p.normalize(p.joinAll(<String>[resolved, ...suffix.reversed]));
      }
      if (entityType == FileSystemEntityType.directory) {
        final resolved = await Directory(current).resolveSymbolicLinks();
        return p.normalize(p.joinAll(<String>[resolved, ...suffix.reversed]));
      }
      final parent = p.dirname(current);
      if (parent == current) {
        throw FileSystemException('无法规范化路径。', rawPath);
      }
      suffix.add(p.basename(current));
      current = parent;
    }
  }

  Future<void> _createLayoutDirectories(String root) async {
    await _ensureDirectoryInsideRoot(root, root);
    for (final category in categoryDirectories) {
      await _ensureDirectoryInsideRoot(root, p.join(root, category));
    }
  }

  Future<void> _ensureDirectoryInsideRoot(
    String root,
    String directoryPath,
  ) async {
    final canonicalRoot = p.normalize(p.absolute(root));
    final normalized = p.normalize(p.absolute(directoryPath));
    if (!_isWithin(normalized, canonicalRoot, allowEqual: true)) {
      throw StateError('生成目录超出项目根路径。');
    }
    final relative = p.relative(normalized, from: canonicalRoot);
    var current = canonicalRoot;
    if (relative == '.') {
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) throw StateError('项目根目录不能是符号链接。');
      if (type == FileSystemEntityType.file) throw StateError('项目根路径被同名文件占用。');
      if (type == FileSystemEntityType.notFound)
        await Directory(current).create(recursive: true);
      return;
    }
    for (final segment in p.split(relative)) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        throw StateError('项目目录包含不安全的路径片段。');
      }
      current = p.join(current, segment);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('项目目录包含符号链接，已拒绝跟随。');
      }
      if (type == FileSystemEntityType.file) {
        throw StateError('项目目录中的路径被同名文件占用：$current');
      }
      if (type == FileSystemEntityType.notFound)
        await Directory(current).create();
    }
  }

  Future<_MaterializeResult> _materializeAsset({
    required String projectId,
    required String rootDirectory,
    required DbRow asset,
  }) async {
    final assetId = _string(asset['asset_id']);
    final expectedSha = _string(asset['blob_sha256']);
    final relativePath = _assetRelativePath(asset);
    if (p.isAbsolute(relativePath) || p.split(relativePath).contains('..')) {
      return _recordMaterializeIssue(
        projectId,
        rootDirectory,
        asset,
        relativePath,
        'conflict',
        'Asset 文件名无法安全映射到项目目录。',
      );
    }
    final target = p.normalize(p.join(rootDirectory, relativePath));
    if (!_isWithin(target, rootDirectory, allowEqual: false)) {
      return _recordMaterializeIssue(
        projectId,
        rootDirectory,
        asset,
        relativePath,
        'conflict',
        'Asset 目标路径超出项目根目录。',
      );
    }
    final stored = _fileRow(projectId, rootDirectory, assetId);
    final rowPath = stored == null
        ? relativePath
        : _string(stored['relative_path']);
    if (rowPath != relativePath ||
        p.isAbsolute(rowPath) ||
        p.split(rowPath).contains('..')) {
      return _recordMaterializeIssue(
        projectId,
        rootDirectory,
        asset,
        rowPath,
        'conflict',
        '已记录的 Asset 目标路径与当前安全路径不一致。',
      );
    }
    final outputPath = p.normalize(p.join(rootDirectory, rowPath));
    if (!_isWithin(outputPath, rootDirectory, allowEqual: false)) {
      return _recordMaterializeIssue(
        projectId,
        rootDirectory,
        asset,
        rowPath,
        'conflict',
        '已记录的 Asset 目标路径超出项目根目录。',
      );
    }

    if (asset['deleted_at_utc'] != null) {
      final type = await FileSystemEntity.type(outputPath, followLinks: false);
      if (type == FileSystemEntityType.link) {
        return _recordMaterializeIssue(
          projectId,
          rootDirectory,
          asset,
          rowPath,
          'conflict',
          '已软删除 Asset 的浏览副本路径变成符号链接；保留原文件且不跟随。',
        );
      }
      String? observedSha;
      if (type == FileSystemEntityType.file) {
        if (_string(asset['blob_state']) == 'committed') {
          try {
            if (await _assets.isSamePhysicalFileAsBlob(
              blobSha256: expectedSha,
              filePath: outputPath,
            )) {
              return _recordMaterializeIssue(
                projectId,
                rootDirectory,
                asset,
                rowPath,
                'conflict',
                '已软删除 Asset 的浏览路径与 Vault 原件是同一个物理文件（可能是硬链接）；保留并拒绝登记。',
              );
            }
          } on FileSystemException {
            // A trashed browse copy is preserved even when its source CAS blob
            // is no longer available for a physical-identity comparison.
          }
        }
        observedSha = await _hashFile(File(outputPath));
      }
      _upsertFileRecord(
        projectId: projectId,
        rootDirectory: rootDirectory,
        asset: asset,
        relativePath: rowPath,
        state: 'soft_deleted',
        observedSha256: observedSha,
        copiedAtUtc: _nullableString(stored?['copied_at_utc']),
      );
      return const _MaterializeResult('soft_deleted');
    }

    final parent = p.dirname(outputPath);
    try {
      await _ensureDirectoryInsideRoot(rootDirectory, parent);
      final outputType = await FileSystemEntity.type(
        outputPath,
        followLinks: false,
      );
      if (outputType == FileSystemEntityType.link ||
          outputType == FileSystemEntityType.directory) {
        return _recordMaterializeIssue(
          projectId,
          rootDirectory,
          asset,
          rowPath,
          'conflict',
          '目标路径由符号链接或目录占用；未覆盖。',
        );
      }
      if (outputType == FileSystemEntityType.file) {
        if (await _assets.isSamePhysicalFileAsBlob(
          blobSha256: expectedSha,
          filePath: outputPath,
        )) {
          return _recordMaterializeIssue(
            projectId,
            rootDirectory,
            asset,
            rowPath,
            'conflict',
            '目标与 Vault 原件是同一个物理文件（可能是硬链接）；拒绝登记为独立浏览副本，以免编辑时改动受管原件。请移走该链接后重试。',
          );
        }
        final actualSha = await _hashFile(File(outputPath));
        if (actualSha == expectedSha) {
          if (stored == null ||
              _stringOrNull(stored['copied_at_utc']) == null) {
            return _recordMaterializeIssue(
              projectId,
              rootDirectory,
              asset,
              rowPath,
              'conflict',
              '目标文件虽与 Vault 原件 SHA-256 相同，但未由项目目录服务生成或登记；为避免接管外部文件，未将其认作浏览副本。请移走后重试。',
              observedSha256: actualSha,
            );
          }
          _upsertFileRecord(
            projectId: projectId,
            rootDirectory: rootDirectory,
            asset: asset,
            relativePath: rowPath,
            state: 'copied',
            observedSha256: actualSha,
            copiedAtUtc:
                _stringOrNull(stored['copied_at_utc']) ??
                DateTime.now().toUtc().toIso8601String(),
          );
          return const _MaterializeResult('already_present');
        }
        return _recordMaterializeIssue(
          projectId,
          rootDirectory,
          asset,
          rowPath,
          stored == null ? 'conflict' : 'externally_changed',
          '浏览副本的 SHA-256 已改变；未将外部修改写回原件，也未覆盖此文件。',
          observedSha256: actualSha,
        );
      }

      if (_string(asset['blob_state']) != 'committed') {
        return _recordMaterializeIssue(
          projectId,
          rootDirectory,
          asset,
          rowPath,
          'source_missing',
          'Vault CAS 原件当前不可用，无法生成浏览副本。',
        );
      }
      _upsertFileRecord(
        projectId: projectId,
        rootDirectory: rootDirectory,
        asset: asset,
        relativePath: rowPath,
        state: 'pending',
      );
      final result = await _assets.writeVerifiedBlobSnapshot(
        blobSha256: expectedSha,
        destinationPath: outputPath,
      );
      final copiedSha = await _hashFile(File(outputPath));
      if (result.sha256 != expectedSha ||
          copiedSha != expectedSha ||
          result.byteSize != _int(asset['byte_size'])) {
        return _recordMaterializeIssue(
          projectId,
          rootDirectory,
          asset,
          rowPath,
          'externally_changed',
          '写入后的浏览副本未通过 SHA-256 或字节数复核；文件已保留供检查。',
          observedSha256: copiedSha,
        );
      }
      _upsertFileRecord(
        projectId: projectId,
        rootDirectory: rootDirectory,
        asset: asset,
        relativePath: rowPath,
        state: 'copied',
        observedSha256: copiedSha,
        copiedAtUtc: DateTime.now().toUtc().toIso8601String(),
      );
      return const _MaterializeResult('copied');
    } on FileSystemException catch (error) {
      final type = await FileSystemEntity.type(outputPath, followLinks: false);
      final conflict = type != FileSystemEntityType.notFound;
      return _recordMaterializeIssue(
        projectId,
        rootDirectory,
        asset,
        rowPath,
        conflict ? 'conflict' : 'missing',
        conflict
            ? '复制目标在写入期间被占用；未覆盖（${error.message}）。'
            : '无法访问复制目标（${error.message}）。',
      );
    } on Object catch (error) {
      return _recordMaterializeIssue(
        projectId,
        rootDirectory,
        asset,
        rowPath,
        'failed',
        '从受管 CAS 生成副本失败：$error',
      );
    }
  }

  _MaterializeResult _recordMaterializeIssue(
    String projectId,
    String rootDirectory,
    DbRow asset,
    String relativePath,
    String state,
    String message, {
    String? observedSha256,
  }) {
    _upsertFileRecord(
      projectId: projectId,
      rootDirectory: rootDirectory,
      asset: asset,
      relativePath: relativePath,
      state: state,
      observedSha256: observedSha256,
      errorMessage: message,
    );
    return _MaterializeResult(
      state,
      ProjectStorageIssue(
        assetId: _string(asset['asset_id']),
        displayName: _string(asset['display_name']),
        state: state,
        message: message,
      ),
    );
  }

  bool _markUnlinkedRetainedFiles({
    required String projectId,
    required String rootDirectory,
    required Set<String> currentAssetIds,
  }) {
    final rows = _database.query(
      '''SELECT asset_id,state FROM project_storage_files
         WHERE project_id=? AND device_id=? AND root_directory=?''',
      <Object?>[projectId, _vault.deviceId, rootDirectory],
    );
    var changed = false;
    for (final row in rows) {
      final assetId = _string(row['asset_id']);
      if (currentAssetIds.contains(assetId) ||
          row['state'] == 'unlinked_retained') {
        continue;
      }
      _database.execute(
        '''UPDATE project_storage_files SET state='unlinked_retained',
             error_message=?,checked_at_utc=?
           WHERE project_id=? AND device_id=? AND root_directory=? AND asset_id=?''',
        <Object?>[
          'AssetLink 已解除；为避免静默删除用户可见文件，此旧副本保留且不再属于当前项目。',
          DateTime.now().toUtc().toIso8601String(),
          projectId,
          _vault.deviceId,
          rootDirectory,
          assetId,
        ],
      );
      changed = true;
    }
    return changed;
  }

  void _upsertFileRecord({
    required String projectId,
    required String rootDirectory,
    required DbRow asset,
    required String relativePath,
    required String state,
    String? observedSha256,
    String? copiedAtUtc,
    String? errorMessage,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    _database.execute(
      '''INSERT INTO project_storage_files
         (project_id,device_id,root_directory,asset_id,relative_path,display_name,
          expected_sha256,observed_sha256,state,copied_at_utc,checked_at_utc,error_message)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
         ON CONFLICT(project_id,device_id,root_directory,asset_id) DO UPDATE SET
          relative_path=excluded.relative_path,display_name=excluded.display_name,
          expected_sha256=excluded.expected_sha256,observed_sha256=excluded.observed_sha256,
          state=excluded.state,copied_at_utc=COALESCE(excluded.copied_at_utc,project_storage_files.copied_at_utc),
          checked_at_utc=excluded.checked_at_utc,error_message=excluded.error_message''',
      <Object?>[
        projectId,
        _vault.deviceId,
        rootDirectory,
        _string(asset['asset_id']),
        relativePath,
        _string(asset['display_name']),
        _string(asset['blob_sha256']),
        observedSha256,
        state,
        copiedAtUtc,
        now,
        errorMessage,
      ],
    );
  }

  Future<bool> _writeManifest(
    String projectId,
    String root,
    String projectTitle,
  ) async {
    final location = _locationRow(projectId, root);
    if (location == null) return false;
    final content = _manifestContent(projectId, root, projectTitle);
    final bytes = utf8.encode(content);
    final expectedSha = sha256.convert(bytes).toString();
    final manifest = File(p.join(root, manifestFileName));
    final type = await FileSystemEntity.type(manifest.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.directory) {
      _setManifestStatus(projectId, root, 'blocked');
      return false;
    }
    if (type == FileSystemEntityType.file) {
      final actualSha = await _hashFile(manifest);
      final pending = _nullableString(location['pending_manifest_sha256']);
      final published = _nullableString(location['manifest_sha256']);
      if (pending != null && actualSha == pending) {
        _finishManifestWrite(projectId, root, pending);
        if (pending == expectedSha) return false;
      } else if (actualSha != published) {
        _setManifestStatus(projectId, root, 'externally_changed');
        return false;
      }
      if (actualSha == expectedSha) {
        _finishManifestWrite(projectId, root, expectedSha);
        return false;
      }
    }

    _database.execute(
      '''UPDATE project_storage_locations
         SET pending_manifest_sha256=?,manifest_status='not_generated',updated_at_utc=?
         WHERE project_id=? AND device_id=? AND root_directory=?''',
      <Object?>[
        expectedSha,
        DateTime.now().toUtc().toIso8601String(),
        projectId,
        _vault.deviceId,
        root,
      ],
    );
    final temporary = File(
      p.join(
        root,
        '.$manifestFileName.partial-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      final currentType = await FileSystemEntity.type(
        manifest.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound &&
          currentType != FileSystemEntityType.notFound) {
        _setManifestStatus(projectId, root, 'externally_changed');
        return false;
      }
      if (type == FileSystemEntityType.file &&
          currentType == FileSystemEntityType.file) {
        final latestSha = await _hashFile(manifest);
        final storedSha = _nullableString(
          _locationRow(projectId, root)?['manifest_sha256'],
        );
        if (latestSha != storedSha && latestSha != expectedSha) {
          _setManifestStatus(projectId, root, 'externally_changed');
          return false;
        }
      }
      await temporary.rename(manifest.path);
      _finishManifestWrite(projectId, root, expectedSha);
      return true;
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  String _manifestContent(String projectId, String root, String projectTitle) {
    final rows = _database.query(
      '''SELECT asset_id,relative_path,display_name,expected_sha256,observed_sha256,state
         FROM project_storage_files
         WHERE project_id=? AND device_id=? AND root_directory=?
         ORDER BY relative_path COLLATE NOCASE,asset_id''',
      <Object?>[projectId, _vault.deviceId, root],
    );
    final document = <String, Object?>{
      'format': 'lab-workspace-project-directory',
      'format_version': 1,
      'project_id': projectId,
      'project_title': projectTitle,
      'generated_at_utc': DateTime.now().toUtc().toIso8601String(),
      'authority':
          'Vault CAS is authoritative; project directory files are browse copies. A retained unlinked file is no longer associated with this project.',
      'external_edits':
          'Edits here never replace managed Assets. Re-generate from the Vault to restore missing copies.',
      'backup_note':
          'This directory is device-local and is not part of the remote Vault blob backup.',
      'files': <Map<String, Object?>>[
        for (final row in rows)
          <String, Object?>{
            'asset_id': _string(row['asset_id']),
            'relative_path': _string(row['relative_path']),
            'display_name': _string(row['display_name']),
            'source_sha256': _string(row['expected_sha256']),
            'browse_copy_sha256': _nullableString(row['observed_sha256']),
            'state': _string(row['state']),
            'project_link_status': row['state'] == 'unlinked_retained'
                ? 'unlinked_retained'
                : 'linked',
            'is_currently_linked': row['state'] != 'unlinked_retained',
          },
      ],
    };
    return '${const JsonEncoder.withIndent('  ').convert(document)}\n';
  }

  void _finishManifestWrite(String projectId, String root, String sha) {
    final now = DateTime.now().toUtc().toIso8601String();
    _database.execute(
      '''UPDATE project_storage_locations
         SET manifest_sha256=?,pending_manifest_sha256=NULL,manifest_status='ready',updated_at_utc=?
         WHERE project_id=? AND device_id=? AND root_directory=?''',
      <Object?>[sha, now, projectId, _vault.deviceId, root],
    );
  }

  void _setManifestStatus(String projectId, String root, String status) {
    _database.execute(
      '''UPDATE project_storage_locations SET manifest_status=?,updated_at_utc=?
         WHERE project_id=? AND device_id=? AND root_directory=?''',
      <Object?>[
        status,
        DateTime.now().toUtc().toIso8601String(),
        projectId,
        _vault.deviceId,
        root,
      ],
    );
  }

  Future<void> _confirmCurrentManifest(String projectId, String root) async {
    final location = _locationRow(projectId, root);
    if (location == null) throw StateError('项目目录记录不存在。');
    final manifest = File(p.join(root, manifestFileName));
    final manifestType = await FileSystemEntity.type(
      manifest.path,
      followLinks: false,
    );
    if (manifestType == FileSystemEntityType.notFound) {
      _setManifestStatus(projectId, root, 'missing');
      throw StateError('项目清单缺失，请重新生成项目目录。');
    }
    if (manifestType != FileSystemEntityType.file) {
      _setManifestStatus(projectId, root, 'blocked');
      throw StateError('项目清单路径不安全，已拒绝读取。');
    }
    final actualSha = await _hashFile(manifest);
    final published = _nullableString(location['manifest_sha256']);
    final pending = _nullableString(location['pending_manifest_sha256']);
    if (actualSha == published) return;
    if (pending != null && actualSha == pending) {
      _finishManifestWrite(projectId, root, pending);
      return;
    }
    _setManifestStatus(projectId, root, 'externally_changed');
    throw StateError('项目清单已被外部修改；未覆盖。');
  }

  String _assetRelativePath(DbRow asset) {
    final kind = _string(asset['kind']);
    final category = switch (kind) {
      'raw' => '原始文件',
      'export' => '导出',
      'report' => '实验记录',
      _ => '分析结果',
    };
    final assetId = _safePathSegment(_string(asset['asset_id']));
    final displayName = _string(asset['display_name']);
    final originalBaseName = p.basename(displayName.replaceAll('\\', '/'));
    return p.join(category, assetId, _safeFileName(originalBaseName));
  }

  static String _safePathSegment(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty || safe == '.' || safe == '..') return 'asset';
    return safe;
  }

  static String _safeFileName(String value) {
    var safe = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[ .]+$'), '')
        .trim();
    if (safe.isEmpty || safe == '.' || safe == '..') safe = '未命名文件';
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$',
      caseSensitive: false,
    ).hasMatch(safe)) {
      safe = '_$safe';
    }
    if (safe.length > 180) {
      final extension = p.extension(safe);
      final base = p.basenameWithoutExtension(safe);
      if (extension.length >= 180) {
        safe = safe.substring(0, 180);
      } else {
        final allowedBaseLength = 180 - extension.length;
        safe = '${base.substring(0, allowedBaseLength)}$extension';
      }
    }
    return safe;
  }

  List<DbRow> _projectAssetRows(String projectId) => _database.query(
    '''
    WITH RECURSIVE
    project_entities(entity_type,entity_id,project_id) AS (
      SELECT 'run',r.run_id,e.project_id
        FROM experiment_runs r JOIN experiments e ON e.experiment_id=r.experiment_id
        JOIN projects p ON p.project_id=e.project_id
        WHERE e.project_id=? AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
      UNION
      SELECT 'step',s.step_id,e.project_id
        FROM step_executions s JOIN experiment_runs r ON r.run_id=s.run_id
        JOIN experiments e ON e.experiment_id=r.experiment_id
        JOIN projects p ON p.project_id=e.project_id
        WHERE e.project_id=? AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
      UNION
      SELECT 'sample',rs.sample_id,e.project_id
        FROM run_samples rs JOIN experiment_runs r ON r.run_id=rs.run_id
        JOIN experiments e ON e.experiment_id=r.experiment_id
        JOIN projects p ON p.project_id=e.project_id
        WHERE e.project_id=? AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
      UNION
      SELECT 'measurement',m.measurement_id,e.project_id
        FROM measurements m JOIN experiment_runs r ON r.run_id=m.run_id
        JOIN experiments e ON e.experiment_id=r.experiment_id
        JOIN projects p ON p.project_id=e.project_id
        WHERE e.project_id=? AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
      UNION
      SELECT 'calculation',c.calculation_id,e.project_id
        FROM calculation_runs c
        JOIN experiment_runs r ON r.run_id=c.run_id OR r.run_id=(
          SELECT s.run_id FROM step_executions s WHERE s.step_id=c.step_id
        )
        JOIN experiments e ON e.experiment_id=r.experiment_id
        JOIN projects p ON p.project_id=e.project_id
        WHERE e.project_id=? AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
      UNION
      SELECT 'analysis',a.analysis_id,e.project_id
        FROM analysis_runs a
        JOIN experiment_runs r ON r.run_id=a.run_id OR r.run_id=(
          SELECT c.run_id FROM calculation_runs c WHERE c.calculation_id=a.calculation_id
        ) OR r.run_id=(
          SELECT s.run_id FROM calculation_runs c
          JOIN step_executions s ON s.step_id=c.step_id
          WHERE c.calculation_id=a.calculation_id
        )
        JOIN experiments e ON e.experiment_id=r.experiment_id
        JOIN projects p ON p.project_id=e.project_id
        WHERE e.project_id=? AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
    ),
    direct_assets(asset_id) AS (
      SELECT DISTINCT l.asset_id FROM asset_links l
      JOIN project_entities pe
        ON pe.entity_type=l.entity_type AND pe.entity_id=l.entity_id
      WHERE pe.project_id=? AND l.removed_at_utc IS NULL
    ),
    project_assets(asset_id) AS (
      SELECT asset_id FROM direct_assets
      UNION
      SELECT a.asset_id FROM assets a JOIN project_assets parent
        ON a.parent_asset_id=parent.asset_id
    )
    SELECT a.asset_id,a.blob_sha256,a.display_name,a.kind,a.parent_asset_id,
           a.deleted_at_utc,b.byte_size,b.state AS blob_state
      FROM project_assets pa JOIN assets a ON a.asset_id=pa.asset_id
      JOIN blob_objects b ON b.sha256=a.blob_sha256
      ORDER BY a.created_at_utc,a.asset_id
    ''',
    <Object?>[
      projectId,
      projectId,
      projectId,
      projectId,
      projectId,
      projectId,
      projectId,
    ],
  );

  List<String> _projectIdsForAsset(String assetId) => _database
      .query(
        '''
        WITH RECURSIVE
        asset_ancestors(asset_id,parent_asset_id) AS (
          SELECT asset_id,parent_asset_id FROM assets WHERE asset_id=?
          UNION
          SELECT parent.asset_id,parent.parent_asset_id FROM assets parent
            JOIN asset_ancestors child ON child.parent_asset_id=parent.asset_id
        ),
        project_entities(entity_type,entity_id,project_id) AS (
          SELECT 'run',r.run_id,e.project_id
            FROM experiment_runs r JOIN experiments e ON e.experiment_id=r.experiment_id
            JOIN projects p ON p.project_id=e.project_id
            WHERE e.project_id IS NOT NULL AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
          UNION
          SELECT 'step',s.step_id,e.project_id FROM step_executions s
            JOIN experiment_runs r ON r.run_id=s.run_id
            JOIN experiments e ON e.experiment_id=r.experiment_id
            JOIN projects p ON p.project_id=e.project_id
            WHERE e.project_id IS NOT NULL AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
          UNION
          SELECT 'sample',rs.sample_id,e.project_id FROM run_samples rs
            JOIN experiment_runs r ON r.run_id=rs.run_id
            JOIN experiments e ON e.experiment_id=r.experiment_id
            JOIN projects p ON p.project_id=e.project_id
            WHERE e.project_id IS NOT NULL AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
          UNION
          SELECT 'measurement',m.measurement_id,e.project_id FROM measurements m
            JOIN experiment_runs r ON r.run_id=m.run_id
            JOIN experiments e ON e.experiment_id=r.experiment_id
            JOIN projects p ON p.project_id=e.project_id
            WHERE e.project_id IS NOT NULL AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
          UNION
          SELECT 'calculation',c.calculation_id,e.project_id FROM calculation_runs c
            JOIN experiment_runs r ON r.run_id=c.run_id OR r.run_id=(
              SELECT s.run_id FROM step_executions s WHERE s.step_id=c.step_id
            )
            JOIN experiments e ON e.experiment_id=r.experiment_id
            JOIN projects p ON p.project_id=e.project_id
            WHERE e.project_id IS NOT NULL AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
          UNION
          SELECT 'analysis',a.analysis_id,e.project_id FROM analysis_runs a
            JOIN experiment_runs r ON r.run_id=a.run_id OR r.run_id=(
              SELECT c.run_id FROM calculation_runs c WHERE c.calculation_id=a.calculation_id
            ) OR r.run_id=(
              SELECT s.run_id FROM calculation_runs c
              JOIN step_executions s ON s.step_id=c.step_id
              WHERE c.calculation_id=a.calculation_id
            )
            JOIN experiments e ON e.experiment_id=r.experiment_id
            JOIN projects p ON p.project_id=e.project_id
            WHERE e.project_id IS NOT NULL AND e.deleted_at_utc IS NULL AND p.deleted_at_utc IS NULL
        )
        SELECT DISTINCT pe.project_id FROM asset_ancestors aa
          JOIN asset_links l ON l.asset_id=aa.asset_id AND l.removed_at_utc IS NULL
          JOIN project_entities pe ON pe.entity_type=l.entity_type AND pe.entity_id=l.entity_id
        ORDER BY pe.project_id
      ''',
        <Object?>[assetId],
      )
      .map((row) => _string(row['project_id']))
      .toList(growable: false);

  DbRow? _projectAssetRow(String projectId, String assetId) =>
      _projectAssetRows(
        projectId,
      ).where((row) => row['asset_id'] == assetId).firstOrNull;

  DbRow _requireProject(String projectId) {
    final rows = _database.query(
      'SELECT project_id,title FROM projects WHERE project_id=? AND deleted_at_utc IS NULL',
      <Object?>[projectId],
    );
    if (rows.isEmpty) throw StateError('项目不存在或已删除：$projectId');
    return rows.single;
  }

  DbRow? _activeLocationRow(String projectId) {
    final rows = _database.query(
      '''SELECT * FROM project_storage_locations
         WHERE project_id=? AND is_active=1 LIMIT 1''',
      <Object?>[projectId],
    );
    return rows.firstOrNull;
  }

  DbRow? _locationRow(String projectId, String root) {
    final rows = _database.query(
      '''SELECT * FROM project_storage_locations
         WHERE project_id=? AND device_id=? AND root_directory=?''',
      <Object?>[projectId, _vault.deviceId, root],
    );
    return rows.firstOrNull;
  }

  DbRow? _fileRow(String projectId, String root, String assetId) {
    final rows = _database.query(
      '''SELECT * FROM project_storage_files
         WHERE project_id=? AND device_id=? AND root_directory=? AND asset_id=?''',
      <Object?>[projectId, _vault.deviceId, root, assetId],
    );
    return rows.firstOrNull;
  }

  String _projectFolderName(String projectId, String title) {
    final safeId = _safePathSegment(projectId);
    final slug = _safeFileName(title).replaceAll(RegExp(r'\s+'), '_');
    final shortSlug = slug.length > 48 ? slug.substring(0, 48) : slug;
    return '${safeId}_$shortSlug';
  }

  bool _pathsOverlap(String left, String right) =>
      _isWithin(left, right, allowEqual: true) ||
      _isWithin(right, left, allowEqual: true);

  bool _isWithin(String path, String parent, {required bool allowEqual}) {
    final normalizedPath = _pathKey(path);
    final normalizedParent = _pathKey(parent);
    if (normalizedPath == normalizedParent) return allowEqual;
    final prefix = normalizedParent.endsWith(p.separator)
        ? normalizedParent
        : '$normalizedParent${p.separator}';
    return normalizedPath.startsWith(prefix);
  }

  String _pathKey(String path) {
    final normalized = p.normalize(p.absolute(path));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static Future<String> _hashFile(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static ProjectStorageManifestStatus _manifestStatus(String status) =>
      switch (status) {
        'ready' => ProjectStorageManifestStatus.ready,
        'missing' => ProjectStorageManifestStatus.missing,
        'externally_changed' => ProjectStorageManifestStatus.externallyChanged,
        'blocked' => ProjectStorageManifestStatus.blocked,
        _ => ProjectStorageManifestStatus.notGenerated,
      };

  static String _string(Object? value) => value?.toString() ?? '';
  static String? _nullableString(Object? value) =>
      value == null ? null : value.toString();
  static String? _stringOrNull(Object? value) =>
      value == null || value.toString().isEmpty ? null : value.toString();
  static int _int(Object? value) =>
      value is int ? value : int.tryParse('$value') ?? 0;
  static DateTime? _dateTime(Object? value) =>
      value == null ? null : DateTime.tryParse(value.toString())?.toUtc();
}

final class _MaterializeResult {
  const _MaterializeResult(this.state, [this.issue]);

  final String state;
  final ProjectStorageIssue? issue;
}

extension _ProjectStorageFirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final iter = this.iterator;
    return iter.moveNext() ? iter.current : null;
  }
}
