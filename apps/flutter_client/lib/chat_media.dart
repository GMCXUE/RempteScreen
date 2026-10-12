import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'chat_message.dart';

const chatVideoMaxBytes = 50 * 1024 * 1024;

class ChatPickedMedia {
  const ChatPickedMedia(
      {required this.kind,
      this.source = '',
      this.bytes,
      this.path,
      this.name = '',
      this.sizeBytes = 0});
  final String kind, source, name;
  final Uint8List? bytes;
  final String? path;
  final int sizeBytes;
}

class ChatDraftMedia extends ChatPickedMedia {
  const ChatDraftMedia(
      {required this.id,
      required super.kind,
      super.source,
      super.bytes,
      super.path,
      super.name,
      super.sizeBytes});
  final String id;
}

Future<List<ChatPickedMedia>> pickChatMedia(
    {required int limit, ImageSource source = ImageSource.gallery}) async {
  final picker = ImagePicker();
  final files = source == ImageSource.camera
      ? [
          await picker.pickImage(
              source: source, maxWidth: 2048, maxHeight: 2048, imageQuality: 85)
        ].whereType<XFile>().toList()
      : await picker.pickMultipleMedia(limit: limit);
  if (files.length > limit) throw Exception('最多添加 9 项图片或视频');
  final result = <ChatPickedMedia>[];
  for (final file in files) {
    final size = await file.length();
    final handle = await File(file.path).open();
    late Uint8List header;
    try {
      header = await handle.read(16);
    } finally {
      await handle.close();
    }
    final video = header.length >= 8 &&
        String.fromCharCodes(header.sublist(4, 8)) == 'ftyp';
    if (video) {
      if (size > chatVideoMaxBytes) throw Exception('视频过大，请选择 50 MB 以内的视频');
      result.add(ChatPickedMedia(
          kind: 'video', path: file.path, name: file.name, sizeBytes: size));
    } else {
      if (size > chatImageMaxBytes) throw Exception('图片过大，请选择 8 MB 以内的图片');
      final bytes = await file.readAsBytes();
      final encoded = bytes.length > 512 * 1024
          ? await compute(chatImageSource, bytes)
          : chatImageSource(bytes);
      result.add(ChatPickedMedia(
          kind: 'image', source: encoded, bytes: bytes, sizeBytes: size));
    }
  }
  return result;
}
