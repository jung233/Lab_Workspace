import 'package:file_picker/file_picker.dart';
import 'package:lab_core/lab_core.dart';

/// Bridges an OS-authorized picker stream into the immutable local AssetStore.
/// File contents are never first accumulated in memory by the UI.
final class AssetImportPicker {
  AssetImportPicker(this.assets);

  final AssetGateway assets;

  Future<List<AssetImportResult>> pickAndImport({
    bool allowMultiple = true,
    AssetKind kind = AssetKind.raw,
    String? parentAssetId,
    List<AssetLinkRef> links = const <AssetLinkRef>[],
  }) async {
    final selected = allowMultiple
        ? await FilePicker.pickFiles(type: FileType.any)
        : <PlatformFile>[
            if (await FilePicker.pickFile(type: FileType.any)
                case final PlatformFile file)
              file,
          ];
    if (selected.isEmpty) return const <AssetImportResult>[];

    final imported = <AssetImportResult>[];
    for (final file in selected) {
      final result = await assets.importFile(
        AssetImportSource(
          displayName: file.name,
          content: file.readAsByteStream(),
          sizeHint: file.lengthSync(),
        ),
        kind: kind,
        parentAssetId: parentAssetId,
        links: links,
      );
      imported.add(result);
    }
    return imported;
  }
}
