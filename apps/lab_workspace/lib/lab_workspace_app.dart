import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

import 'app_theme.dart';
import 'platform/workspace_services.dart';
import 'screens/workspace_shell.dart';

class LabWorkspaceApp extends StatefulWidget {
  const LabWorkspaceApp({
    required this.core,
    required this.services,
    super.key,
  });

  final LabCore core;
  final WorkspaceServices services;

  @override
  State<LabWorkspaceApp> createState() => _LabWorkspaceAppState();
}

class _LabWorkspaceAppState extends State<LabWorkspaceApp> {
  @override
  void dispose() {
    unawaited(widget.core.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lab Workspace',
      debugShowCheckedModeBanner: false,
      theme: buildLabWorkspaceTheme(),
      home: WorkspaceShell(core: widget.core, services: widget.services),
    );
  }
}
