import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

Future<Uint8List?> cropAvatarPhoto(
    BuildContext context, Uint8List bytes) async {
  if (bytes.length > 8 * 1024 * 1024) throw Exception('图片过大，请选择 8 MB 以内的图片');
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width * descriptor.height > 24000000) {
      throw Exception('图片尺寸过大，请选择较小的图片');
    }
    final ratio =
        math.min(1.0, 1024 / math.max(descriptor.width, descriptor.height));
    codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * ratio).round(),
        targetHeight: (descriptor.height * ratio).round());
    image = (await codec.getNextFrame()).image;
    if (!context.mounted) return null;
    final route = MaterialPageRoute<Uint8List>(
        builder: (_) => AvatarCropScreen(image: image!));
    final result = await Navigator.of(context).push(route);
    await route.completed;
    return result;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

class AvatarCropScreen extends StatefulWidget {
  const AvatarCropScreen({super.key, required this.image});
  final ui.Image image;
  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  double _zoom = 1;
  late Offset _center = Offset(widget.image.width / 2, widget.image.height / 2);
  bool _saving = false;
  Rect get _crop {
    final side = math.min(widget.image.width, widget.image.height) / _zoom;
    final cx =
        _center.dx.clamp(side / 2, widget.image.width - side / 2).toDouble();
    final cy =
        _center.dy.clamp(side / 2, widget.image.height - side / 2).toDouble();
    return Rect.fromCenter(center: Offset(cx, cy), width: side, height: side);
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
        widget.image,
        _crop,
        const Rect.fromLTWH(0, 0, 256, 256),
        Paint()..filterQuality = FilterQuality.high);
    final picture = recorder.endRecording();
    ui.Image? output;
    try {
      output = await picture.toImage(256, 256);
      final bytes = await output.toByteData(format: ui.ImageByteFormat.png);
      if (mounted) Navigator.pop(context, bytes!.buffer.asUint8List());
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法处理图片，请重试')));
      }
    } finally {
      output?.dispose();
      picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('调整头像')),
        body: SafeArea(
            child: Center(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text('拖动图片调整位置',
                              style: TextStyle(color: Color(0xFF8390A5))),
                          const SizedBox(height: 24),
                          LayoutBuilder(
                              builder: (context, constraints) =>
                                  GestureDetector(
                                      onPanUpdate: _saving
                                          ? null
                                          : (details) => setState(() {
                                                _center = _crop.center -
                                                    details.delta *
                                                        (_crop.width /
                                                            constraints
                                                                .maxWidth);
                                                _center = _crop.center;
                                              }),
                                      child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(28),
                                          child: AspectRatio(
                                              aspectRatio: 1,
                                              child: CustomPaint(
                                                  painter: _CropPainter(
                                                      widget.image, _crop)))))),
                          const SizedBox(height: 20),
                          Semantics(
                              label: '缩放图片',
                              child: Slider(
                                  value: _zoom,
                                  min: 1,
                                  max: 4,
                                  onChanged: _saving
                                      ? null
                                      : (value) => setState(() {
                                            _zoom = value;
                                            _center = _crop.center;
                                          }))),
                          const SizedBox(height: 16),
                          SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                  onPressed: _saving ? null : _finish,
                                  child: Text(_saving ? '处理中…' : '使用照片'))),
                        ]))))),
      ));
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.crop);
  final ui.Image image;
  final Rect crop;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawImageRect(image, crop,
      Offset.zero & size, Paint()..filterQuality = FilterQuality.high);
  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.crop != crop;
}
