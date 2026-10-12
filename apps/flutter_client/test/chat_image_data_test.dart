import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/chat_message.dart';

void main() {
  test('8 MB 图片编码可以完整校验和解码，不溢出调用栈', () {
    final bytes = Uint8List(8 * 1024 * 1024);
    bytes.setRange(0, 3, [0xff, 0xd8, 0xff]);
    bytes[bytes.length - 1] = 123;
    final source = chatImageSource(bytes);
    final decoded = chatImageBytes(source);
    expect(decoded?.length, bytes.length);
    expect(decoded?.first, 0xff);
    expect(decoded?.last, 123);
  });
  test('格式限制保留，拒绝超限、非法字符、损坏填充和非图片链接', () {
    for (final mime in ['jpeg', 'png', 'webp']) {
      expect(chatImageBytes('data:image/$mime;base64,YQ=='), [97]);
      expect(chatImageBytes('data:image/$mime;base64,YWFh'), [97, 97, 97]);
    }
    for (final source in [
      'https://example.test/image.png',
      'data:image/svg+xml;base64,YQ==',
      'data:image/png;base64,',
      'data:image/png;base64,Y',
      'data:image/png;base64,YQ',
      'data:image/png;base64,YQ=',
      'data:image/png;base64,YQ===',
      'data:image/png;base64,Y=Q=',
      'data:image/png;base64,YQ==\n',
      'data:image/png;base64,Y%51==',
      'data:image/png;base64,${'A' * (((chatImageMaxBytes + 2) ~/ 3) * 4 + 4)}',
    ]) {
      expect(chatImageBytes(source), isNull);
    }
    final invalidTail = 'data:image/png;base64,${'A' * (4 * 1024 * 1024)}!';
    expect(chatImageBytes(invalidTail), isNull);
  });
}
