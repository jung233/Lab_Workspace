import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:lab_core/lab_core.dart';
import 'package:image/image.dart' as img;

/// Flutter-native PNG preview and exact 8/16-bit integer pixel decoder.
/// Quantitative decoding supports non-interlaced PNG color types 0/2/4/6 only;
/// other formats fail with a clear unsupported-format error.
final class PngImagePlatform
    implements ImagePreviewRenderer, OriginalImagePixelDecoder {
  PngImagePlatform({this.maxSourceBytes = 256 * 1024 * 1024});

  final int maxSourceBytes;

  @override
  Future<ImageMetadata> inspect(
    AssetOpenHandle source, {
    int pageIndex = 0,
  }) async {
    if (pageIndex != 0) {
      throw const ImageServiceException(
        'IMAGE_PAGE_UNAVAILABLE',
        'PNG images contain only page 0.',
      );
    }
    final parsed = _Png.parse(await _read(source));
    return ImageMetadata(
      width: parsed.width,
      height: parsed.height,
      mimeType: 'image/png',
      bitDepth: parsed.bitDepth,
      channels: parsed.channelNames,
    );
  }

  @override
  Future<ImagePreview> createPreview(
    AssetOpenHandle source, {
    required int maxBytes,
    int pageIndex = 0,
  }) async {
    if (pageIndex != 0) {
      throw const ImageServiceException(
        'IMAGE_PAGE_UNAVAILABLE',
        'PNG images contain only page 0.',
      );
    }
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final sourceBytes = await _read(source);
    final parsed = _Png.parse(sourceBytes);
    var width = parsed.width;
    var height = parsed.height;
    final scale = (2048 / (width > height ? width : height)).clamp(0.01, 1.0);
    width = (width * scale).round().clamp(1, 2048).toInt();
    height = (height * scale).round().clamp(1, 2048).toInt();
    for (var attempt = 0; attempt < 8; attempt++) {
      final codec = await ui.instantiateImageCodec(
        sourceBytes,
        targetWidth: width,
        targetHeight: height,
      );
      final frame = await codec.getNextFrame();
      final bytes = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final actualWidth = frame.image.width;
      final actualHeight = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (bytes == null) {
        throw const ImageServiceException(
          'IMAGE_PREVIEW_FAILED',
          'Flutter could not render a safe PNG preview.',
        );
      }
      final png = bytes.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
      if (png.length <= maxBytes) {
        return ImagePreview(
          dataUri: 'data:image/png;base64,${base64Encode(png)}',
          byteLength: png.length,
          width: actualWidth,
          height: actualHeight,
        );
      }
      width = (width * 0.72).floor().clamp(1, width).toInt();
      height = (height * 0.72).floor().clamp(1, height).toInt();
      if (width == 1 && height == 1 && attempt > 0) break;
    }
    throw const ImageServiceException(
      'IMAGE_PREVIEW_TOO_LARGE',
      'A preview could not fit within the approved upload limit.',
    );
  }

  @override
  Future<OriginalImagePixelPlane> decodeOriginal(
    AssetOpenHandle source, {
    int pageIndex = 0,
  }) async {
    if (pageIndex != 0) {
      throw const ImageServiceException(
        'IMAGE_PAGE_UNAVAILABLE',
        'PNG images contain only page 0.',
      );
    }
    if (source.validationLevel != AssetValidationLevel.verified) {
      throw const ImageServiceException(
        'IMAGE_FULL_SHA_REQUIRED',
        'PNG pixels require a fully verified Asset snapshot.',
      );
    }
    final parsed = _Png.parse(await _read(source));
    if (!const {8, 16}.contains(parsed.bitDepth) || parsed.interlace != 0) {
      throw const ImageServiceException(
        'IMAGE_PNG_FORMAT_UNSUPPORTED',
        'Quantitative PNG decoding requires non-interlaced 8-bit or 16-bit integer pixels.',
      );
    }
    final raw = ZLibDecoder().convert(parsed.compressedData);
    final expectedLength = (parsed.rowBytes + 1) * parsed.height;
    if (raw.length != expectedLength) {
      throw const ImageServiceException(
        'IMAGE_PNG_INVALID',
        'PNG decompressed dimensions did not match the header.',
      );
    }
    final reconstructed = Uint8List(parsed.rowBytes * parsed.height);
    var inputOffset = 0;
    for (var y = 0; y < parsed.height; y++) {
      final filter = raw[inputOffset++];
      final rowStart = y * parsed.rowBytes;
      final priorStart = rowStart - parsed.rowBytes;
      for (var x = 0; x < parsed.rowBytes; x++) {
        final value = raw[inputOffset++];
        final left = x >= parsed.bytesPerPixel
            ? reconstructed[rowStart + x - parsed.bytesPerPixel]
            : 0;
        final up = y > 0 ? reconstructed[priorStart + x] : 0;
        final upperLeft = y > 0 && x >= parsed.bytesPerPixel
            ? reconstructed[priorStart + x - parsed.bytesPerPixel]
            : 0;
        reconstructed[rowStart + x] = switch (filter) {
          0 => value,
          1 => (value + left) & 0xff,
          2 => (value + up) & 0xff,
          3 => (value + ((left + up) >> 1)) & 0xff,
          4 => (value + _paeth(left, up, upperLeft)) & 0xff,
          _ => throw const ImageServiceException(
            'IMAGE_PNG_FILTER_UNSUPPORTED',
            'PNG contains an invalid row filter.',
          ),
        };
      }
    }
    final channels = <OriginalImagePixelChannel>[];
    for (var channel = 0; channel < parsed.channelsPerPixel; channel++) {
      final values = List<int>.generate(parsed.width * parsed.height, (index) {
        final y = index ~/ parsed.width;
        final x = index % parsed.width;
        final sampleOffset =
            y * parsed.rowBytes +
            (x * parsed.channelsPerPixel + channel) * (parsed.bitDepth ~/ 8);
        if (parsed.bitDepth == 8) return reconstructed[sampleOffset];
        return (reconstructed[sampleOffset] << 8) |
            reconstructed[sampleOffset + 1];
      }, growable: false);
      channels.add(
        OriginalImagePixelChannel(
          index: channel,
          name: parsed.channelNames[channel],
          values: values,
        ),
      );
    }
    return OriginalImagePixelPlane(
      width: parsed.width,
      height: parsed.height,
      bitDepth: parsed.bitDepth,
      channels: List.unmodifiable(channels),
    );
  }

  /// Creates an explicitly derived PNG for review/export. These pixels are
  /// marked derived and are never accepted by [decodeOriginal].
  Future<Uint8List> renderDerivedRoi(
    AssetOpenHandle source, {
    required ImageRoi roi,
    required bool overlay,
    int pageIndex = 0,
  }) async {
    if (pageIndex != 0) {
      throw const ImageServiceException(
        'IMAGE_PAGE_UNAVAILABLE',
        'PNG images contain only page 0.',
      );
    }
    if (source.validationLevel != AssetValidationLevel.verified ||
        source.asset.kind != AssetKind.raw) {
      throw const ImageServiceException(
        'IMAGE_ORIGINAL_REQUIRED',
        'Derived image tools require a verified raw original.',
      );
    }
    final bytes = await _read(source);
    final metadata = _Png.parse(bytes);
    if (!roi.inside(metadata.width, metadata.height)) {
      throw const ImageServiceException(
        'IMAGE_ROI_OUT_OF_BOUNDS',
        'Reviewed ROI is outside the original image.',
      );
    }
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final outputWidth = overlay ? image.width : roi.width;
    final outputHeight = overlay ? image.height : roi.height;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()),
    );
    if (overlay) {
      canvas.drawImage(image, ui.Offset.zero, ui.Paint());
      canvas.drawRect(
        ui.Rect.fromLTWH(
          roi.x.toDouble(),
          roi.y.toDouble(),
          roi.width.toDouble(),
          roi.height.toDouble(),
        ),
        ui.Paint()
          ..color = const ui.Color(0x88ff2020)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = (image.width / 800).clamp(2, 8).toDouble(),
      );
    } else {
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(
          roi.x.toDouble(),
          roi.y.toDouble(),
          roi.width.toDouble(),
          roi.height.toDouble(),
        ),
        ui.Rect.fromLTWH(0, 0, roi.width.toDouble(), roi.height.toDouble()),
        ui.Paint(),
      );
    }
    final picture = recorder.endRecording();
    final rendered = await picture.toImage(outputWidth, outputHeight);
    final encoded = await rendered.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    codec.dispose();
    picture.dispose();
    rendered.dispose();
    if (encoded == null) {
      throw const ImageServiceException(
        'IMAGE_DERIVED_RENDER_FAILED',
        'Could not render the approved derived image.',
      );
    }
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  }

  Future<Uint8List> _read(AssetOpenHandle source) async {
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in source.openRead()) {
      length += chunk.length;
      if (length > maxSourceBytes) {
        throw const ImageServiceException(
          'IMAGE_SOURCE_TOO_LARGE',
          'This image exceeds the native decoder memory limit.',
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs();
    final pb = (p - b).abs();
    final pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    return pb <= pc ? b : c;
  }
}

/// Trusted decoder for common unsigned integer TIFF pages. The package decoder
/// preserves uint8/uint16 channel values; all palette, alpha, signed, floating,
/// CMYK, tiled/planar variants that do not decode as one or three unsigned
/// channels are rejected before consent or quantitative work.
final class TiffImagePlatform
    implements ImagePreviewRenderer, OriginalImagePixelDecoder {
  TiffImagePlatform({
    this.maxSourceBytes = 256 * 1024 * 1024,
    this.maxPixels = 5_000_000,
  });

  final int maxSourceBytes;
  final int maxPixels;

  @override
  Future<ImageMetadata> inspect(
    AssetOpenHandle source, {
    int pageIndex = 0,
  }) async {
    final bytes = await _read(source);
    final decoder = img.TiffDecoder(maxPixels: maxPixels);
    final info = decoder.startDecode(bytes);
    final pageCount = decoder.numFrames();
    if (info == null ||
        pageCount <= 0 ||
        pageIndex < 0 ||
        pageIndex >= pageCount) {
      throw const ImageServiceException(
        'IMAGE_TIFF_INVALID',
        'TIFF directory or requested page is invalid.',
      );
    }
    final page = decoder.decodeFrame(pageIndex);
    if (page == null) {
      throw const ImageServiceException(
        'IMAGE_TIFF_INVALID',
        'TIFF page could not be decoded.',
      );
    }
    try {
      _validateIntegerPage(page);
      final bitDepth = page.bitsPerChannel;
      final baseNames = page.numChannels == 1
          ? const ['gray']
          : const ['red', 'green', 'blue'];
      return ImageMetadata(
        width: page.width,
        height: page.height,
        mimeType: 'image/tiff',
        bitDepth: bitDepth,
        channels: [
          for (final name in baseNames) 'page ${pageIndex + 1} · $name',
        ],
        pageIndex: pageIndex,
        pageCount: pageCount,
      );
    } finally {}
  }

  @override
  Future<ImagePreview> createPreview(
    AssetOpenHandle source, {
    required int maxBytes,
    int pageIndex = 0,
  }) async {
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final bytes = await _read(source);
    final decoder = img.TiffDecoder(maxPixels: maxPixels);
    if (decoder.startDecode(bytes) == null ||
        pageIndex < 0 ||
        pageIndex >= decoder.numFrames()) {
      throw const ImageServiceException(
        'IMAGE_TIFF_INVALID',
        'TIFF directory or requested page is invalid.',
      );
    }
    final page = decoder.decodeFrame(pageIndex);
    if (page == null) {
      throw const ImageServiceException(
        'IMAGE_TIFF_INVALID',
        'TIFF page could not be decoded.',
      );
    }
    try {
      _validateIntegerPage(page);
      var width = page.width;
      var height = page.height;
      final scale = (2048 / (width > height ? width : height)).clamp(0.01, 1.0);
      width = (width * scale).round().clamp(1, 2048).toInt();
      height = (height * scale).round().clamp(1, 2048).toInt();
      for (var attempt = 0; attempt < 8; attempt++) {
        final resized = img.copyResize(
          page,
          width: width,
          height: height,
          interpolation: img.Interpolation.average,
        );
        final png = img.encodePng(resized);
        if (png.length <= maxBytes) {
          return ImagePreview(
            dataUri: 'data:image/png;base64,${base64Encode(png)}',
            byteLength: png.length,
            width: width,
            height: height,
          );
        }
        width = (width * 0.72).floor().clamp(1, width).toInt();
        height = (height * 0.72).floor().clamp(1, height).toInt();
        if (width == 1 && height == 1) break;
      }
      throw const ImageServiceException(
        'IMAGE_PREVIEW_TOO_LARGE',
        'TIFF preview could not fit within the approved upload limit.',
      );
    } finally {}
  }

  @override
  Future<OriginalImagePixelPlane> decodeOriginal(
    AssetOpenHandle source, {
    int pageIndex = 0,
  }) async {
    if (source.validationLevel != AssetValidationLevel.verified) {
      throw const ImageServiceException(
        'IMAGE_FULL_SHA_REQUIRED',
        'TIFF pixels require a fully verified Asset snapshot.',
      );
    }
    final bytes = await _read(source);
    final decoder = img.TiffDecoder(maxPixels: maxPixels);
    if (decoder.startDecode(bytes) == null ||
        pageIndex < 0 ||
        pageIndex >= decoder.numFrames()) {
      throw const ImageServiceException(
        'IMAGE_TIFF_INVALID',
        'TIFF directory or requested page is invalid.',
      );
    }
    final page = decoder.decodeFrame(pageIndex);
    if (page == null) {
      throw const ImageServiceException(
        'IMAGE_TIFF_INVALID',
        'TIFF page could not be decoded.',
      );
    }
    _validateIntegerPage(page);
    final names = page.numChannels == 1
        ? const ['gray']
        : const ['red', 'green', 'blue'];
    final channels = <OriginalImagePixelChannel>[];
    for (var channel = 0; channel < names.length; channel++) {
      final values = List<int>.generate(page.width * page.height, (index) {
        final pixel = page.getPixel(index % page.width, index ~/ page.width);
        final value = pixel[channel];
        if (value is! int) {
          throw const ImageServiceException(
            'IMAGE_TIFF_PRECISION_UNSUPPORTED',
            'TIFF decoder did not return integer samples.',
          );
        }
        return value;
      }, growable: false);
      channels.add(
        OriginalImagePixelChannel(
          index: channel,
          name: 'page ${pageIndex + 1} · ${names[channel]}',
          values: values,
        ),
      );
    }
    return OriginalImagePixelPlane(
      width: page.width,
      height: page.height,
      bitDepth: page.bitsPerChannel,
      channels: List.unmodifiable(channels),
    );
  }

  Future<Uint8List> renderDerivedRoi(
    AssetOpenHandle source, {
    required ImageRoi roi,
    required bool overlay,
    int pageIndex = 0,
  }) async {
    if (source.validationLevel != AssetValidationLevel.verified ||
        source.asset.kind != AssetKind.raw) {
      throw const ImageServiceException(
        'IMAGE_ORIGINAL_REQUIRED',
        'Derived image tools require a verified raw original.',
      );
    }
    final bytes = await _read(source);
    final decoder = img.TiffDecoder(maxPixels: maxPixels);
    if (decoder.startDecode(bytes) == null ||
        pageIndex < 0 ||
        pageIndex >= decoder.numFrames()) {
      throw const ImageServiceException(
        'IMAGE_TIFF_INVALID',
        'TIFF directory or requested page is invalid.',
      );
    }
    final page = decoder.decodeFrame(pageIndex);
    if (page == null) {
      throw const ImageServiceException(
        'IMAGE_TIFF_INVALID',
        'TIFF page could not be decoded.',
      );
    }
    _validateIntegerPage(page);
    if (!roi.inside(page.width, page.height)) {
      throw const ImageServiceException(
        'IMAGE_ROI_OUT_OF_BOUNDS',
        'Reviewed ROI is outside the original TIFF page.',
      );
    }
    final output = overlay
        ? img.Image.from(page)
        : img.copyCrop(
            page,
            x: roi.x,
            y: roi.y,
            width: roi.width,
            height: roi.height,
          );
    if (overlay) {
      img.drawRect(
        output,
        x1: roi.x,
        y1: roi.y,
        x2: roi.x + roi.width - 1,
        y2: roi.y + roi.height - 1,
        color: img.ColorRgb8(255, 32, 32),
        thickness: (page.width / 800).clamp(2, 8),
      );
    }
    return Uint8List.fromList(img.encodePng(output));
  }

  void _validateIntegerPage(img.Image page) {
    final bitDepth = page.bitsPerChannel;
    if (page.width <= 0 ||
        page.height <= 0 ||
        page.width * page.height > maxPixels ||
        page.hasPalette ||
        !{1, 3}.contains(page.numChannels) ||
        !{8, 16}.contains(bitDepth) ||
        (bitDepth == 8 && page.format != img.Format.uint8) ||
        (bitDepth == 16 && page.format != img.Format.uint16)) {
      throw const ImageServiceException(
        'IMAGE_TIFF_FORMAT_UNSUPPORTED',
        'TIFF requires unsigned 8/16-bit grayscale or RGB pixels without palette, alpha, float, or signed channels.',
      );
    }
  }

  Future<Uint8List> _read(AssetOpenHandle source) async {
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in source.openRead()) {
      length += chunk.length;
      if (length > maxSourceBytes) {
        throw const ImageServiceException(
          'IMAGE_SOURCE_TOO_LARGE',
          'This TIFF exceeds the native decoder memory limit.',
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}

/// Dispatches by verified file signature, not filename extension.
final class ScientificImagePlatform
    implements ImagePreviewRenderer, OriginalImagePixelDecoder {
  ScientificImagePlatform({PngImagePlatform? png, TiffImagePlatform? tiff})
    : png = png ?? PngImagePlatform(),
      tiff = tiff ?? TiffImagePlatform();

  final PngImagePlatform png;
  final TiffImagePlatform tiff;

  Future<Uint8List> _readHeader(AssetOpenHandle source) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in source.openRead()) {
      builder.add(chunk);
      if (builder.length >= 8) break;
    }
    return builder.takeBytes();
  }

  Future<Object> _platform(AssetOpenHandle source) async {
    final bytes = await _readHeader(source);
    if (bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71) {
      return png;
    }
    if (bytes.length >= 4 &&
        ((bytes[0] == 0x49 &&
                bytes[1] == 0x49 &&
                bytes[2] == 42 &&
                bytes[3] == 0) ||
            (bytes[0] == 0x4d &&
                bytes[1] == 0x4d &&
                bytes[2] == 0 &&
                bytes[3] == 42))) {
      return tiff;
    }
    throw const ImageServiceException(
      'IMAGE_FORMAT_UNSUPPORTED',
      'Only supported PNG and integer TIFF files can enter the scientific image workflow.',
    );
  }

  @override
  Future<ImageMetadata> inspect(
    AssetOpenHandle source, {
    int pageIndex = 0,
  }) async => switch (await _platform(source)) {
    PngImagePlatform p => p.inspect(source, pageIndex: pageIndex),
    TiffImagePlatform t => t.inspect(source, pageIndex: pageIndex),
    _ => throw StateError('Unsupported image platform.'),
  };

  @override
  Future<ImagePreview> createPreview(
    AssetOpenHandle source, {
    required int maxBytes,
    int pageIndex = 0,
  }) async => switch (await _platform(source)) {
    PngImagePlatform p => p.createPreview(
      source,
      maxBytes: maxBytes,
      pageIndex: pageIndex,
    ),
    TiffImagePlatform t => t.createPreview(
      source,
      maxBytes: maxBytes,
      pageIndex: pageIndex,
    ),
    _ => throw StateError('Unsupported image platform.'),
  };

  @override
  Future<OriginalImagePixelPlane> decodeOriginal(
    AssetOpenHandle source, {
    int pageIndex = 0,
  }) async => switch (await _platform(source)) {
    PngImagePlatform p => p.decodeOriginal(source, pageIndex: pageIndex),
    TiffImagePlatform t => t.decodeOriginal(source, pageIndex: pageIndex),
    _ => throw StateError('Unsupported image platform.'),
  };

  Future<Uint8List> renderDerivedRoi(
    AssetOpenHandle source, {
    required ImageRoi roi,
    required bool overlay,
    int pageIndex = 0,
  }) async => switch (await _platform(source)) {
    PngImagePlatform p => p.renderDerivedRoi(
      source,
      roi: roi,
      overlay: overlay,
      pageIndex: pageIndex,
    ),
    TiffImagePlatform t => t.renderDerivedRoi(
      source,
      roi: roi,
      overlay: overlay,
      pageIndex: pageIndex,
    ),
    _ => throw StateError('Unsupported image platform.'),
  };
}

final class AssetImageDerivedOutputWriter implements ImageDerivedOutputWriter {
  const AssetImageDerivedOutputWriter(this.assets);

  final AssetGateway assets;

  @override
  Future<AssetId> saveReport({
    required AssetId original,
    required String analysisId,
    required String traceId,
    required String report,
  }) async {
    final imported = await assets.importFile(
      AssetImportSource(
        displayName: 'image-calculation-$traceId.json',
        mediaType: 'application/json',
        content: Stream<List<int>>.value(utf8.encode(report)),
        sizeHint: utf8.encode(report).length,
      ),
      kind: AssetKind.report,
      parentAssetId: original,
      links: [
        AssetLinkRef(
          targetType: 'asset',
          targetId: original,
          role: 'image_trace_source',
          metadata: {'trace_id': traceId},
        ),
        AssetLinkRef(
          targetType: 'analysis_run',
          targetId: analysisId,
          role: 'image_calculation_trace',
          metadata: {'trace_id': traceId},
        ),
      ],
      metadata: {
        'trace_id': traceId,
        'generated_pixels_used_for_quantitation': false,
      },
    );
    return imported.asset.assetId;
  }
}

final class _Png {
  _Png({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.interlace,
    required this.compressedData,
  });

  final int width;
  final int height;
  final int bitDepth;
  final int colorType;
  final int interlace;
  final Uint8List compressedData;

  int get channelsPerPixel => switch (colorType) {
    0 => 1,
    2 => 3,
    _ => 0,
  };
  int get bytesPerPixel => channelsPerPixel * (bitDepth ~/ 8);
  int get rowBytes => width * bytesPerPixel;
  List<String> get channelNames => switch (colorType) {
    0 => const ['gray'],
    2 => const ['red', 'green', 'blue'],
    _ => const [],
  };

  static _Png parse(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 33 ||
        List<int>.generate(8, (i) => bytes[i]).toString() !=
            signature.toString()) {
      throw const ImageServiceException(
        'IMAGE_FORMAT_UNSUPPORTED',
        'Only structurally valid PNG images are supported by this image workflow.',
      );
    }
    final data = ByteData.sublistView(bytes);
    var offset = 8;
    int? width;
    int? height;
    int? bitDepth;
    int? colorType;
    int? interlace;
    final idat = BytesBuilder(copy: false);
    var seenHeader = false;
    var seenEnd = false;
    while (offset + 12 <= bytes.length) {
      final length = data.getUint32(offset, Endian.big);
      final chunkStart = offset + 4;
      final type = ascii.decode(
        bytes.sublist(chunkStart, chunkStart + 4),
        allowInvalid: false,
      );
      final payloadStart = chunkStart + 4;
      final payloadEnd = payloadStart + length;
      final chunkEnd = payloadEnd + 4;
      if (length > 256 * 1024 * 1024 || chunkEnd > bytes.length) {
        throw const ImageServiceException(
          'IMAGE_PNG_INVALID',
          'PNG chunk length is invalid.',
        );
      }
      final expectedCrc = data.getUint32(payloadEnd, Endian.big);
      if (_crc32(bytes, chunkStart, payloadEnd) != expectedCrc) {
        throw const ImageServiceException(
          'IMAGE_PNG_CRC_MISMATCH',
          'PNG chunk checksum did not match.',
        );
      }
      if (type == 'IHDR') {
        if (seenHeader || length != 13) {
          throw const ImageServiceException(
            'IMAGE_PNG_INVALID',
            'PNG header is duplicated or malformed.',
          );
        }
        width = data.getUint32(payloadStart, Endian.big);
        height = data.getUint32(payloadStart + 4, Endian.big);
        bitDepth = bytes[payloadStart + 8];
        colorType = bytes[payloadStart + 9];
        if (bytes[payloadStart + 10] != 0 || bytes[payloadStart + 11] != 0) {
          throw const ImageServiceException(
            'IMAGE_PNG_INVALID',
            'PNG compression or filter method is unsupported.',
          );
        }
        interlace = bytes[payloadStart + 12];
        seenHeader = true;
      } else if (type == 'IDAT') {
        if (!seenHeader || seenEnd) {
          throw const ImageServiceException(
            'IMAGE_PNG_INVALID',
            'PNG image data ordering is invalid.',
          );
        }
        idat.add(bytes.sublist(payloadStart, payloadEnd));
      } else if (type == 'IEND') {
        seenEnd = true;
        break;
      }
      offset = chunkEnd;
    }
    if (!seenHeader ||
        !seenEnd ||
        width == null ||
        height == null ||
        bitDepth == null ||
        colorType == null ||
        interlace == null ||
        width <= 0 ||
        height <= 0 ||
        width * height > 5_000_000) {
      throw const ImageServiceException(
        'IMAGE_PNG_INVALID',
        'PNG dimensions or required chunks are invalid.',
      );
    }
    // Scientific input requires alpha-free grayscale or RGB. Reject alpha
    // layouts during inspect(), before the consent dialog can offer upload.
    final supported = {0, 2}.contains(colorType);
    if (!supported || !{8, 16}.contains(bitDepth)) {
      throw const ImageServiceException(
        'IMAGE_PNG_FORMAT_UNSUPPORTED',
        'PNG color type or bit depth is not supported.',
      );
    }
    final parsed = _Png(
      width: width,
      height: height,
      bitDepth: bitDepth,
      colorType: colorType,
      interlace: interlace,
      compressedData: idat.takeBytes(),
    );
    if (parsed.channelsPerPixel == 0 ||
        parsed.rowBytes <= 0 ||
        parsed.rowBytes * height > 512 * 1024 * 1024) {
      throw const ImageServiceException(
        'IMAGE_PNG_TOO_LARGE',
        'PNG decoded pixel plane exceeds the local memory limit.',
      );
    }
    return parsed;
  }
}

int _crc32(Uint8List bytes, int start, int end) {
  var crc = 0xffffffff;
  for (var index = start; index < end; index++) {
    crc ^= bytes[index];
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
