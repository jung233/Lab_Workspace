import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// Shown when no selected Vault can be safely opened. It never creates a new
/// database; the user must choose an existing Vault directory explicitly.
final class VaultSelectionGate extends StatefulWidget {
  const VaultSelectionGate({
    required this.reason,
    required this.openExisting,
    super.key,
  });

  final String reason;
  final Future<Widget> Function(String rootDirectory) openExisting;

  @override
  State<VaultSelectionGate> createState() => _VaultSelectionGateState();
}

final class _VaultSelectionGateState extends State<VaultSelectionGate> {
  bool _busy = false;
  String? _error;
  Widget? _opened;

  Future<void> _chooseVault() async {
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择已有 Lab Workspace Vault 目录',
    );
    if (directory == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final app = await widget.openExisting(directory);
      if (mounted) setState(() => _opened = app);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final opened = _opened;
    if (opened != null) return opened;
    return MaterialApp(
      title: 'Lab Workspace · 选择 Vault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176B67)),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('选择 Lab Workspace Vault',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Text(widget.reason),
                  const SizedBox(height: 12),
                  const Text(
                    '应用不会用空数据库替代无法打开的 Vault。请选择包含有效 workspace.sqlite3 的已有 Vault 根目录。',
                  ),
                  if (_error case final error?) ...[
                    const SizedBox(height: 12),
                    SelectableText(error, style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    )),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _busy ? null : _chooseVault,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_open),
                    label: const Text('选择并验证已有 Vault'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
