import 'dart:async';
import 'dart:io';
import 'api.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class ChatVideoViewer extends StatefulWidget {
  const ChatVideoViewer({super.key, required this.load, this.validate});
  final Future<File> Function() load;
  final Future<void> Function()? validate;
  @override
  State<ChatVideoViewer> createState() => _ChatVideoViewerState();
}

class _ChatVideoViewerState extends State<ChatVideoViewer> {
  VideoPlayerController? _controller;
  File? _file;
  String? _error;
  bool _controls = true,
      _loading = false,
      _validating = false,
      _unavailable = false;
  Timer? _validationTimer;
  @override
  void initState() {
    super.initState();
    _load();
    if (widget.validate != null) {
      _validationTimer =
          Timer.periodic(const Duration(seconds: 3), (_) => _validate());
    }
  }

  Future<void> _validate() async {
    if (_validating || !mounted) return;
    _validating = true;
    try {
      await widget.validate!();
    } on ApiException catch (error) {
      if (mounted &&
          ([401, 403, 404, 410].contains(error.status) ||
              error.code == 'session_changed')) {
        _validationTimer?.cancel();
        _unavailable = true;
        final controller = _controller, file = _file;
        setState(() {
          _controller = null;
          _file = null;
          _error = error.message;
        });
        await _cleanup(controller, file);
      }
    } catch (_) {
      // A temporary network outage does not interrupt an already downloaded video.
    } finally {
      _validating = false;
    }
  }

  Future<void> _load() async {
    if (_loading || _unavailable) return;
    _loading = true;
    setState(() => _error = null);
    File? file;
    VideoPlayerController? controller;
    try {
      file = await widget.load();
      if (!mounted || _unavailable) {
        await file.parent.delete(recursive: true);
        return;
      }
      controller = VideoPlayerController.file(file);
      await controller.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || _unavailable) {
        await controller.dispose();
        await file.parent.delete(recursive: true);
        return;
      }
      _file = file;
      _controller = controller;
      controller.addListener(_changed);
      setState(() {});
      await controller.play();
    } catch (error) {
      _controller = null;
      _file = null;
      controller?.removeListener(_changed);
      await controller?.dispose();
      if (file != null && await file.parent.exists()) {
        await file.parent.delete(recursive: true);
      }
      if (mounted) {
        setState(
            () => _error = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      _loading = false;
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _cleanup(VideoPlayerController? controller, File? file) async {
    if (controller != null) {
      controller.removeListener(_changed);
      await controller.dispose();
    }
    if (file != null && await file.parent.exists()) {
      await file.parent.delete(recursive: true);
    }
  }

  @override
  void dispose() {
    _validationTimer?.cancel();
    unawaited(_cleanup(_controller, _file));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('视频')),
        body: _error != null
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!, style: const TextStyle(color: Colors.white)),
                if (!_unavailable)
                  TextButton(onPressed: _load, child: const Text('重试'))
              ]))
            : c == null
                ? const Center(child: CircularProgressIndicator())
                : SafeArea(
                    child: Stack(children: [
                    Positioned.fill(
                        child: GestureDetector(
                            onTap: () => setState(() => _controls = !_controls),
                            child: Center(
                                child: AspectRatio(
                                    aspectRatio: c.value.aspectRatio,
                                    child: VideoPlayer(c))))),
                    if (_controls)
                      Positioned(
                          left: 12,
                          right: 12,
                          bottom: 12,
                          child: ColoredBox(
                              color: const Color(0xAA172131),
                              child: Row(children: [
                                IconButton(
                                    tooltip: c.value.isPlaying ? '暂停' : '播放',
                                    onPressed: () => c.value.isPlaying
                                        ? c.pause()
                                        : c.play(),
                                    icon: Icon(
                                        c.value.isPlaying
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        color: Colors.white)),
                                Expanded(
                                    child: VideoProgressIndicator(c,
                                        allowScrubbing: true)),
                                IconButton(
                                    tooltip:
                                        c.value.volume == 0 ? '打开声音' : '静音',
                                    onPressed: () => c
                                        .setVolume(c.value.volume == 0 ? 1 : 0),
                                    icon: Icon(
                                        c.value.volume == 0
                                            ? Icons.volume_off_rounded
                                            : Icons.volume_up_rounded,
                                        color: Colors.white))
                              ])))
                  ])));
  }
}
