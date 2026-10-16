import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';
import 'package:path_provider/path_provider.dart';

import '../lab_workspace_app.dart';
import '../platform/active_vault_selection.dart';
import '../platform/workspace_services.dart';
import 'vault_selection_gate.dart';

Future<Widget> bootstrapLabWorkspace() async {
  final supportDirectory = await getApplicationSupportDirectory();
  final selection = ActiveVaultSelection.atSupportDirectory(supportDirectory);
  ActiveVaultRecord? savedSelection;
  try {
    savedSelection = await selection.read();
  } on Object catch (error) {
    return _selectionGate(
      selection,
      '已保存的 Vault 选择文件无法读取：$error',
    );
  }

  if (savedSelection != null) {
    try {
      return await _openExisting(
        savedSelection.rootDirectory,
        selection: selection,
        expectedVaultId: savedSelection.vaultId,
      );
    } on Object catch (error) {
      return _selectionGate(
        selection,
        '上次选择的 Vault 无法验证或打开。请选择有效的已有 Vault。\n$error',
      );
    }
  }

  final legacyDefaultRoot = _join(
    supportDirectory.path,
    'LabWorkspace',
    'Vaults',
    'primary',
  );
  final legacyDatabase = File(_join(legacyDefaultRoot, 'workspace.sqlite3'));
  if (await legacyDatabase.exists()) {
    try {
      return await _openExisting(legacyDefaultRoot, selection: selection);
    } on Object catch (error) {
      return _selectionGate(
        selection,
        '默认 Vault 文件存在但无法通过验证。为避免创建空数据库，请选择有效 Vault。\n$error',
      );
    }
  }

  try {
    final core = await LabCore.initialize(directoryPath: legacyDefaultRoot);
    await selection.write(_recordFor(core));
    return await _workspace(core);
  } on Object catch (error) {
    return _selectionGate(selection, '创建首次使用的本机 Vault 失败。\n$error');
  }
}

Widget _selectionGate(ActiveVaultSelection selection, String reason) =>
    VaultSelectionGate(
      reason: reason,
      openExisting: (rootDirectory) =>
          _openExisting(rootDirectory, selection: selection),
    );

Future<Widget> _openExisting(
  String rootDirectory, {
  required ActiveVaultSelection selection,
  String? expectedVaultId,
}) async {
  final core = await LabCore.openExisting(directoryPath: rootDirectory);
  if (expectedVaultId != null && core.vault.id != expectedVaultId) {
    await core.close();
    throw StateError(
      'Vault ID does not match the saved selection; refusing to open another Vault.',
    );
  }
  try {
    await selection.write(_recordFor(core));
    return await _workspace(core);
  } on Object {
    await core.close();
    rethrow;
  }
}

ActiveVaultRecord _recordFor(LabCore core) => ActiveVaultRecord(
  rootDirectory: core.vault.context.rootDirectory,
  vaultId: core.vault.id,
  deviceId: core.vault.deviceId,
);

Future<Widget> _workspace(LabCore core) async {
  try {
    final services = WorkspaceServices(core);
    await services.initialize();
    return LabWorkspaceApp(core: core, services: services);
  } on Object {
    await core.close();
    rethrow;
  }
}

String _join(String first, [String? second, String? third, String? fourth]) {
  final components = <String>[first];
  if (second != null) components.add(second);
  if (third != null) components.add(third);
  if (fourth != null) components.add(fourth);
  return components.join(Platform.pathSeparator);
}
