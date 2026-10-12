import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show compute;
import 'native_service.dart';
import 'compact_feedback.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Unsent media belongs to the composer and keeps its id through send retries.
class ChatDraftImage {
  const ChatDraftImage(
      {required this.id, required this.source, required this.bytes});
  final String id, source;
  final Uint8List bytes;
}

bool canRecallMessage(Map<String, dynamic> message, String accountId,
    {DateTime? now}) {
  final created = int.tryParse('${message['createdAt']}');
  return message['senderId'] == accountId &&
      const ['text', 'image', 'video'].contains(message['kind'] ?? 'text') &&
      created != null &&
      (now ?? DateTime.now()).millisecondsSinceEpoch - created <= 120000;
}

const chatImageMaxBytes = 8 * 1024 * 1024;

Uint8List? chatImageBytes(dynamic value) {
  // A whole-image RegExp can exhaust the VM's regexp stack on valid large
  // images. Check bounded headers and scan the payload without backtracking.
  if (value is! String ||
      value.length > ((chatImageMaxBytes + 2) ~/ 3) * 4 + 32) {
    return null;
  }
  const headers = [
    'data:image/jpeg;base64,',
    'data:image/png;base64,',
    'data:image/webp;base64,'
  ];
  var start = -1;
  for (final header in headers) {
    if (value.startsWith(header)) {
      start = header.length;
      break;
    }
  }
  if (start < 0 || start == value.length) return null;
  var end = value.length;
  while (end > start && value.codeUnitAt(end - 1) == 61) {
    end--;
  }
  final padding = value.length - end, length = end - start;
  if (padding > 2 ||
      length == 0 ||
      length % 4 == 1 ||
      (value.length - start) % 4 != 0 ||
      length * 3 ~/ 4 > chatImageMaxBytes) {
    return null;
  }
  for (var i = start; i < end; i++) {
    final c = value.codeUnitAt(i);
    if (!((c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        (c >= 48 && c <= 57) ||
        c == 43 ||
        c == 47)) {
      return null;
    }
  }
  try {
    return base64Decode(value.substring(start));
  } catch (_) {
    return null;
  }
}

Future<String?> pickChatImage(
    {ImageSource source = ImageSource.gallery}) async {
  // Apply the same file-size limit and server-side compression as desktop.
  final file = await ImagePicker().pickImage(
      source: source,
      maxWidth: source == ImageSource.camera ? 2048 : null,
      maxHeight: source == ImageSource.camera ? 2048 : null,
      imageQuality: source == ImageSource.camera ? 85 : null);
  if (file == null) return null;
  if (await file.length() > chatImageMaxBytes) {
    throw Exception('图片过大，请选择 8 MB 以内的图片');
  }
  final bytes = await file.readAsBytes();
  return bytes.length > 512 * 1024
      ? compute(chatImageSource, bytes)
      : chatImageSource(bytes);
}

String chatImageSource(Uint8List bytes) {
  if (bytes.length > chatImageMaxBytes) {
    throw Exception('图片过大，请选择 8 MB 以内的图片');
  }
  // Determine actual encoded type; picker may transcode a PNG/HEIC to JPEG.
  final mime = bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8
      ? 'jpeg'
      : bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50
          ? 'png'
          : bytes.length >= 12 &&
                  ascii.decode(bytes.sublist(0, 4), allowInvalid: true) ==
                      'RIFF' &&
                  ascii.decode(bytes.sublist(8, 12), allowInvalid: true) ==
                      'WEBP'
              ? 'webp'
              : null;
  if (mime == null) throw Exception('请选择 JPG、PNG 或 WebP 图片');
  return 'data:image/$mime;base64,${base64Encode(bytes)}';
}

class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble(
      {super.key,
      required this.message,
      required this.mine,
      required this.timeLabel,
      required this.onActions,
      required this.onOpenImage,
      this.onRetry});
  // Pending images remain local until the server acknowledges the message.
  final Map<String, dynamic> message;
  final bool mine;
  final String timeLabel;
  final VoidCallback onActions, onOpenImage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (message['kind'] == 'recalled') {
      return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
              child: Text(mine ? '你撤回了一条消息' : '对方撤回了一条消息',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF98A2B3)))));
    }
    final video = message['kind'] == 'video';
    final image = message['kind'] == 'image' || video;
    final media = video ? message['video'] : message['image'];
    final bytes = image
        ? message['_localImageBytes'] as Uint8List? ??
            chatImageBytes(media?['thumbnail'])
        : null;
    final width = math.max(1.0, (media?['width'] as num?)?.toDouble() ?? 240);
    final height = math.max(1.0, (media?['height'] as num?)?.toDouble() ?? 240);
    final scale = math.min(
        video ? double.infinity : 1.0,
        math.min(
            math.min(240.0, MediaQuery.sizeOf(context).width * .68 - 10) /
                width,
            280 / height));
    return Semantics(
      label: '消息，长按打开菜单',
      child: GestureDetector(
        onLongPress: onActions,
        onSecondaryTap: onActions,
        child: Container(
          constraints:
              BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .68),
          padding: image
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
              color: image
                  ? Colors.transparent
                  : mine
                      ? const Color(0xFFEAF1FF)
                      : Colors.white,
              borderRadius: BorderRadius.circular(14)),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (image)
                  Semantics(
                      key: ValueKey('chat-open-${message['id']}'),
                      button: true,
                      label: video ? '播放视频' : '查看图片',
                      child: GestureDetector(
                          onTap: onOpenImage,
                          child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child:
                                  Stack(alignment: Alignment.center, children: [
                                bytes == null
                                    ? SizedBox(
                                        width: 180,
                                        height: 140,
                                        child: Center(
                                            child:
                                                Text(video ? '视频' : '图片无法显示')))
                                    : SizedBox(
                                        width: width * scale,
                                        height: height * scale,
                                        child: Image.memory(bytes,
                                            cacheWidth: 480,
                                            fit: BoxFit.contain,
                                            gaplessPlayback: true,
                                            errorBuilder: (_, __, ___) =>
                                                const SizedBox(
                                                    width: 180,
                                                    height: 140,
                                                    child: Center(
                                                        child:
                                                            Text('图片无法显示'))))),
                                if (video)
                                  const Icon(Icons.play_circle_fill_rounded,
                                      color: Colors.white, size: 48),
                                if (video && media?['duration'] != null)
                                  Positioned(
                                      right: 8,
                                      bottom: 8,
                                      child: Text(
                                          videoDuration(
                                              (media['duration'] as num)
                                                  .toInt()),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              backgroundColor:
                                                  Color(0xAA172131)))),
                              ]))))
                else ...[
                  if (message['kind'] == 'call')
                    Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                              message['call']?['kind'] == 'video'
                                  ? Icons.videocam_outlined
                                  : Icons.call_outlined,
                              size: 16,
                              color: const Color(0xFF667085)),
                          const SizedBox(width: 6),
                          Text(
                              message['call']?['kind'] == 'video'
                                  ? '视频通话'
                                  : '语音通话',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF667085)))
                        ])),
                  Text(message['text'] as String? ?? '',
                      style: const TextStyle(fontSize: 14, height: 1.5)),
                ],
                const SizedBox(height: 6),
                if (message['localStatus'] != null)
                  message['localStatus'] == 'failed'
                      ? Tooltip(
                          message: message['localError'] ?? '发送失败',
                          child: TextButton(
                              onPressed: onRetry,
                              style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFFD92D20),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  minimumSize: const Size(0, 28)),
                              child: const Text('发送失败 · 重试',
                                  style: TextStyle(fontSize: 12))))
                      : const Text('发送中',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF98A2B3))),
                Text(timeLabel,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF98A2B3))),
              ]),
        ),
      ),
    );
  }
}

class ChatImageViewer extends StatefulWidget {
  const ChatImageViewer(
      {super.key, required this.load, this.thumbnail, this.onCopy});
  final Future<Uint8List> Function() load;
  final Uint8List? thumbnail;
  final Future<void> Function()? onCopy;
  @override
  State<ChatImageViewer> createState() => _ChatImageViewerState();
}

class _ChatImageViewerState extends State<ChatImageViewer> {
  final _transform = TransformationController();
  final _feedback = CompactFeedback();
  Uint8List? _image;
  Size? _imageSize;
  Size _viewport = Size.zero;
  String? _error;
  bool _loading = true, _copying = false;
  int _quarterTurns = 0, _generation = 0;
  double get _scale => _transform.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    _image = widget.thumbnail;
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _feedback.dismiss();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await widget.load();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      Size size;
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          size =
              Size(descriptor.width.toDouble(), descriptor.height.toDouble());
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
      if (!mounted || generation != _generation) return;
      _transform.value = Matrix4.identity();
      setState(() {
        _image = bytes;
        _imageSize = size;
        _quarterTurns = 0;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _fit() => _transform.value = Matrix4.identity();
  void _zoom(double value) {
    final scale = value.clamp(1.0, 8.0);
    _transform.value = Matrix4.identity()
      ..translateByDouble(_viewport.width * (1 - scale) / 2,
          _viewport.height * (1 - scale) / 2, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _original() {
    if (_imageSize == null) return;
    final size = _quarterTurns.isOdd
        ? Size(_imageSize!.height, _imageSize!.width)
        : _imageSize!;
    final fit = math.min(1.0,
        math.min(_viewport.width / size.width, _viewport.height / size.height));
    if (fit > 0) _zoom(1 / fit);
  }

  Future<void> _copy() async {
    if (_copying || _loading || _error != null) return;
    setState(() => _copying = true);
    try {
      if (widget.onCopy != null) {
        await widget.onCopy!();
      } else {
        final bytes = await widget.load();
        if (!mounted) return;
        await NativeChatClipboard.copyImage(bytes);
        if (!await NativeChatClipboard.hasSystemFeedback() && mounted) {
          _feedback.show(context, '图片已复制');
        }
      }
    } catch (_) {
      if (mounted) _feedback.show(context, '复制失败，请重试', error: true);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Widget _tool(String label, IconData icon, VoidCallback? action) => IconButton(
      tooltip: label,
      onPressed: action,
      style: IconButton.styleFrom(
          foregroundColor: const Color(0xFFEAECF0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      icon: Icon(icon, size: 21),
      constraints: const BoxConstraints(minWidth: 38, minHeight: 44),
      padding: const EdgeInsets.all(8));

  @override
  Widget build(BuildContext context) {
    final ready = !_loading && _error == null && _imageSize != null;
    return Scaffold(
      backgroundColor: const Color(0xFF101828),
      body: SafeArea(
          child: Column(children: [
        Container(
            height: 52,
            color: const Color(0xFF182130),
            child: IconTheme(
                data: const IconThemeData(color: Color(0xFFEAECF0)),
                child: Row(children: [
                  _tool('返回', Icons.arrow_back_rounded,
                      () => Navigator.of(context).pop()),
                  _tool('适应窗口', Icons.fit_screen_outlined, ready ? _fit : null),
                  ValueListenableBuilder<Matrix4>(
                      valueListenable: _transform,
                      builder: (_, matrix, __) => Row(children: [
                            _tool(
                                '缩小',
                                Icons.remove_rounded,
                                ready && _scale > 1
                                    ? () => _zoom(_scale / 1.25)
                                    : null),
                            SizedBox(
                                width: 42,
                                child: Text('${(_scale * 100).round()}%',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFFC0C8D5)))),
                            _tool(
                                '放大',
                                Icons.add_rounded,
                                ready && _scale < 8
                                    ? () => _zoom(_scale * 1.25)
                                    : null),
                          ])),
                  SizedBox(
                      width: 38,
                      child: TextButton(
                          style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFFEAECF0),
                              minimumSize: const Size(38, 44),
                              padding: EdgeInsets.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          onPressed: ready ? _original : null,
                          child: const Text('1:1',
                              style: TextStyle(fontSize: 12)))),
                  _tool(
                      '旋转',
                      Icons.rotate_right_rounded,
                      ready
                          ? () {
                              _fit();
                              setState(() =>
                                  _quarterTurns = (_quarterTurns + 1) % 4);
                            }
                          : null),
                  const Spacer(),
                  _tool('复制图片', Icons.copy_outlined,
                      ready && !_copying ? _copy : null),
                ]))),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: LayoutBuilder(builder: (_, constraints) {
          _viewport = constraints.biggest;
          return GestureDetector(
              onDoubleTap: ready ? () => _scale > 1 ? _fit() : _zoom(2) : null,
              child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 1,
                  maxScale: 8,
                  child: SizedBox(
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                      child: _image == null
                          ? const Center(
                              child: Text('正在加载图片…',
                                  style: TextStyle(color: Color(0xFF8B8F96))))
                          : RotatedBox(
                              quarterTurns: _quarterTurns,
                              child: Image.memory(_image!,
                                  fit: BoxFit.scaleDown,
                                  errorBuilder: (_, __, ___) => const Center(
                                      child: Text('图片无法显示',
                                          style: TextStyle(
                                              color: Color(0xFF8B8F96)))))))));
        })),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Text(_error!, style: const TextStyle(color: Color(0xFFC0C8D5))),
                TextButton(onPressed: _load, child: const Text('重试')),
              ])),
      ])),
    );
  }
}

String videoDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  return "${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}";
}
