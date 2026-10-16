import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lab_core/lab_core.dart';

/// The exact user-reviewed values that the caller may bind to an approval.
/// This dialog deliberately does not create approvals or execute image tools.
final class RoiReviewDecision {
  const RoiReviewDecision({
    required this.signalRoi,
    required this.channelIndex,
    required this.backgroundMethod,
    required this.suggestionIndex,
    this.backgroundRoi,
  });

  final ImageRoi signalRoi;
  final ImageRoi? backgroundRoi;
  final int channelIndex;
  final String backgroundMethod;
  final int suggestionIndex;
}

/// Shows model candidates beside the verified original-page preview and asks
/// the user to select, edit, and explicitly confirm the final pixel region.
Future<RoiReviewDecision?> showRoiReviewDialog({
  required BuildContext context,
  required ImagePlan plan,
  required Uint8List originalPreviewPng,
}) => showDialog<RoiReviewDecision>(
  context: context,
  builder: (_) =>
      _RoiReviewDialog(plan: plan, originalPreviewPng: originalPreviewPng),
);

final class _RoiReviewDialog extends StatefulWidget {
  const _RoiReviewDialog({
    required this.plan,
    required this.originalPreviewPng,
  });

  final ImagePlan plan;
  final Uint8List originalPreviewPng;

  @override
  State<_RoiReviewDialog> createState() => _RoiReviewDialogState();
}

final class _RoiReviewDialogState extends State<_RoiReviewDialog> {
  late final List<TextEditingController> _signal;
  late final List<TextEditingController> _background;
  late int _suggestionIndex;
  late int _channelIndex;
  String _backgroundMethod = 'none';
  String? _validationMessage;

  ImagePlan get _plan => widget.plan;
  RoiSuggestion get _suggestion => _plan.suggestions[_suggestionIndex];

  @override
  void initState() {
    super.initState();
    _suggestionIndex = 0;
    _channelIndex = 0;
    _signal = _controllers(_plan.suggestions.first.roi);
    _background = _controllers(const ImageRoi(x: 0, y: 0, width: 1, height: 1));
  }

  List<TextEditingController> _controllers(ImageRoi roi) => [
    TextEditingController(text: '${roi.x}'),
    TextEditingController(text: '${roi.y}'),
    TextEditingController(text: '${roi.width}'),
    TextEditingController(text: '${roi.height}'),
  ];

  @override
  void dispose() {
    for (final controller in [..._signal, ..._background]) {
      controller.dispose();
    }
    super.dispose();
  }

  ImageRoi? _readRoi(List<TextEditingController> fields) {
    final values = fields
        .map((field) => int.tryParse(field.text.trim()))
        .toList();
    if (values.any((value) => value == null)) return null;
    return ImageRoi(
      x: values[0]!,
      y: values[1]!,
      width: values[2]!,
      height: values[3]!,
    );
  }

  void _selectSuggestion(int? index) {
    if (index == null) return;
    final next = _plan.suggestions[index].roi;
    setState(() {
      _suggestionIndex = index;
      for (final pair in <(TextEditingController, int)>[
        (_signal[0], next.x),
        (_signal[1], next.y),
        (_signal[2], next.width),
        (_signal[3], next.height),
      ]) {
        pair.$1.text = '${pair.$2}';
      }
      _validationMessage = null;
    });
  }

  void _confirm() {
    final metadata = _plan.metadata;
    final signal = _readRoi(_signal);
    final background = _backgroundMethod == 'mean_subtract'
        ? _readRoi(_background)
        : null;
    if (signal == null ||
        !signal.inside(metadata.width, metadata.height) ||
        (_backgroundMethod == 'mean_subtract' &&
            (background == null ||
                !background.inside(metadata.width, metadata.height)))) {
      setState(() {
        _validationMessage =
            '请输入有效的正整数区域。区域必须完全位于原图范围内（${metadata.width} × ${metadata.height}）。';
      });
      return;
    }
    Navigator.of(context).pop(
      RoiReviewDecision(
        signalRoi: signal,
        backgroundRoi: background,
        channelIndex: _channelIndex,
        backgroundMethod: _backgroundMethod,
        suggestionIndex: _suggestionIndex,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final metadata = _plan.metadata;
    final signal = _readRoi(_signal);
    final background = _backgroundMethod == 'mean_subtract'
        ? _readRoi(_background)
        : null;
    final validSignal =
        signal?.inside(metadata.width, metadata.height) ?? false;
    final validBackground =
        background == null ||
        background.inside(metadata.width, metadata.height);
    final canConfirm =
        validSignal &&
        validBackground &&
        _channelIndex >= 0 &&
        _channelIndex < metadata.channels.length;

    return AlertDialog(
      title: const Text('审阅并批准原图 ROI'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '原图第 ${metadata.pageIndex + 1}/${metadata.pageCount} 页 · '
                '${metadata.width} × ${metadata.height} px · ${metadata.bitDepth}-bit · ${metadata.mimeType}',
              ),
              const SizedBox(height: 4),
              Text('原图 SHA-256：${_plan.sourceSha256}'),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _suggestionIndex,
                decoration: const InputDecoration(
                  labelText: '模型提出的候选 ROI（逐项审阅）',
                ),
                items: [
                  for (var i = 0; i < _plan.suggestions.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${i + 1}. ${_plan.suggestions[i].label} · '
                        '置信度 ${(_plan.suggestions[i].confidence ?? 0).toStringAsFixed(2)}',
                      ),
                    ),
                ],
                onChanged: _selectSuggestion,
              ),
              const SizedBox(height: 8),
              Text(_suggestion.explanation),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AspectRatio(
                  aspectRatio: metadata.width / metadata.height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(widget.originalPreviewPng, fit: BoxFit.fill),
                      CustomPaint(
                        painter: _RoiPreviewPainter(
                          imageWidth: metadata.width,
                          imageHeight: metadata.height,
                          signal: signal,
                          background: background,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '预览来自已验证原图当前页；叠加框按原图像素坐标缩放。预览像素不参与定量。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              Text(
                '信号 ROI：x=${signal?.x ?? '—'}, y=${signal?.y ?? '—'}, '
                '宽=${signal?.width ?? '—'}, 高=${signal?.height ?? '—'}',
              ),
              for (final pair in <(String, TextEditingController)>[
                ('左上 X（原图像素）', _signal[0]),
                ('左上 Y（原图像素）', _signal[1]),
                ('宽度（原图像素）', _signal[2]),
                ('高度（原图像素）', _signal[3]),
              ])
                TextField(
                  controller: pair.$2,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: pair.$1),
                  onChanged: (_) => setState(() => _validationMessage = null),
                ),
              DropdownButtonFormField<int>(
                initialValue: _channelIndex,
                decoration: const InputDecoration(labelText: '用于计算的原始像素通道'),
                items: [
                  for (var i = 0; i < metadata.channels.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text('$i · ${metadata.channels[i]}'),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _channelIndex = value);
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: _backgroundMethod,
                decoration: const InputDecoration(labelText: '背景校正'),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('不做背景校正')),
                  DropdownMenuItem(
                    value: 'mean_subtract',
                    child: Text('减去用户指定背景 ROI 均值'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _backgroundMethod = value);
                },
              ),
              if (_backgroundMethod == 'mean_subtract') ...[
                const SizedBox(height: 8),
                Text(
                  '背景 ROI：x=${background?.x ?? '—'}, y=${background?.y ?? '—'}, '
                  '宽=${background?.width ?? '—'}, 高=${background?.height ?? '—'}',
                ),
                for (final pair in <(String, TextEditingController)>[
                  ('背景 X（原图像素）', _background[0]),
                  ('背景 Y（原图像素）', _background[1]),
                  ('背景宽度（原图像素）', _background[2]),
                  ('背景高度（原图像素）', _background[3]),
                ])
                  TextField(
                    controller: pair.$2,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: pair.$1),
                    onChanged: (_) => setState(() => _validationMessage = null),
                  ),
              ],
              if (_validationMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _validationMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              const Text('明确确认后才会创建绑定本机、原图 SHA、页、通道与坐标的审批记录；模型建议不会自动批准。'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canConfirm ? _confirm : null,
          child: const Text('我已核对并批准这些精确参数'),
        ),
      ],
    );
  }
}

final class _RoiPreviewPainter extends CustomPainter {
  const _RoiPreviewPainter({
    required this.imageWidth,
    required this.imageHeight,
    required this.signal,
    required this.background,
  });

  final int imageWidth;
  final int imageHeight;
  final ImageRoi? signal;
  final ImageRoi? background;

  @override
  void paint(Canvas canvas, Size size) {
    final signalRoi = signal;
    if (signalRoi != null && signalRoi.inside(imageWidth, imageHeight)) {
      _draw(canvas, size, signalRoi, const Color(0xFFFFC107));
    }
    final backgroundRoi = background;
    if (backgroundRoi != null &&
        backgroundRoi.inside(imageWidth, imageHeight)) {
      _draw(canvas, size, backgroundRoi, const Color(0xFF00E5FF));
    }
  }

  void _draw(Canvas canvas, Size size, ImageRoi roi, Color color) {
    final rect = Rect.fromLTWH(
      roi.x / imageWidth * size.width,
      roi.y / imageHeight * size.height,
      roi.width / imageWidth * size.width,
      roi.height / imageHeight * size.height,
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _RoiPreviewPainter oldDelegate) =>
      oldDelegate.imageWidth != imageWidth ||
      oldDelegate.imageHeight != imageHeight ||
      oldDelegate.signal != signal ||
      oldDelegate.background != background;
}
