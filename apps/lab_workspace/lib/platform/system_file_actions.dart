import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:lab_core/lab_core.dart';

/// Opens only a temporary read-only copy obtained from an AssetOpenHandle.
/// The Vault CAS path is never passed to an operating-system viewer.
final class SystemFileActions {
  SystemFileActions({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('lab_workspace/native_files');

  final MethodChannel _channel;

  Future<void> open(AssetOpenHandle handle) async {
    final path = await _materialize(handle);
    await _channel.invokeMethod<void>('openFile', <String, Object?>{
      'path': path,
      'mimeType': handle.asset.mediaType ?? 'application/octet-stream',
    });
  }

  Future<void> reveal(AssetOpenHandle handle) async {
    final path = await _materialize(handle);
    await _channel.invokeMethod<void>('revealFile', <String, Object?>{
      'path': path,
    });
  }

  Future<void> share(AssetOpenHandle handle) async {
    final path = await _materialize(handle);
    await _channel.invokeMethod<void>('shareFile', <String, Object?>{
      'path': path,
      'mimeType': handle.asset.mediaType ?? 'application/octet-stream',
    });
  }

  Future<String> _materialize(AssetOpenHandle handle) async {
    final tempDirectory = await getTemporaryDirectory();
    final exportDirectory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}lab_workspace_open',
    );
    await exportDirectory.create(recursive: true);
    final safeName = _safeName(handle.asset.displayName);
    final path =
        '${exportDirectory.path}${Platform.pathSeparator}${handle.asset.assetId}_$safeName';
    final destination = File(path);
    if (await destination.exists()) await destination.delete();
    final output = destination.openWrite(mode: FileMode.writeOnly);
    try {
      await for (final chunk in handle.openRead()) {
        output.add(chunk);
      }
      await output.flush();
    } catch (_) {
      await output.close();
      try {
        await destination.delete();
      } on FileSystemException {
        // Preserve the original stream/write failure.
      }
      rethrow;
    } finally {
      await handle.close();
    }
    await output.close();
    return path;
  }

  String _safeName(String value) {
    final leaf = value.replaceAll('\\', '/').split('/').last.trim();
    final cleaned = leaf.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'asset.bin' : cleaned;
  }
}
