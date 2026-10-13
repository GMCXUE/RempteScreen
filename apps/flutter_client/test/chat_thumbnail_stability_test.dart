import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/chat_message.dart';

Map<String, dynamic> imageMessage(String source, {String id = 'photo'}) => {
      'id': id,
      'kind': 'image',
      'image': {'thumbnail': source, 'width': 64, 'height': 64},
    };

Widget conversationBubble(Map<String, dynamic> message,
        {String time = '12:00'}) =>
    MaterialApp(
        home: Scaffold(
            body: Center(
                child: ChatMessageBubble(
                    message: message,
                    mine: false,
                    timeLabel: time,
                    onActions: () {},
                    onOpenImage: () {}))));

Uint8List thumbnailBytes(WidgetTester tester) {
  final provider = tester.widget<Image>(find.byType(Image)).image;
  final memory = provider is ResizeImage ? provider.imageProvider : provider;
  return (memory as MemoryImage).bytes;
}

void main() {
  final catBytes = File('assets/avatars/cat.png').readAsBytesSync();
  final catSource = chatImageSource(catBytes);
  final dogSource =
      chatImageSource(File('assets/avatars/dog.png').readAsBytesSync());

  testWidgets('连续输入和轮询重建保留同一缩略图缓存与图片状态', (tester) async {
    await tester.pumpWidget(conversationBubble(imageMessage(catSource)));
    await tester.pumpAndSettle();
    final bytes = thumbnailBytes(tester);
    final imageProvider = tester.widget<Image>(find.byType(Image)).image;
    final imageState = tester.state(find.byType(Image));
    for (var i = 0; i < 40; i++) {
      // Polling reconstructs maps/strings; typing changes surrounding metadata.
      final source = String.fromCharCodes(catSource.codeUnits);
      await tester
          .pumpWidget(conversationBubble(imageMessage(source), time: '12:$i'));
      expect(identical(thumbnailBytes(tester), bytes), isTrue);
      expect(tester.widget<Image>(find.byType(Image)).image, imageProvider);
      expect(tester.state(find.byType(Image)), same(imageState));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('来源原地修改和列表换消息不会沿用上一张图片', (tester) async {
    final message = imageMessage(catSource);
    await tester.pumpWidget(conversationBubble(message));
    await tester.pumpAndSettle();
    final oldBytes = thumbnailBytes(tester);
    final oldImageState = tester.state(find.byType(Image));

    (message['image'] as Map)['thumbnail'] = dogSource;
    await tester.pumpWidget(conversationBubble(message));
    expect(identical(thumbnailBytes(tester), oldBytes), isFalse);
    expect(thumbnailBytes(tester), chatImageBytes(dogSource));
    expect(tester.state(find.byType(Image)), isNot(same(oldImageState)));
    await tester.pumpAndSettle();

    final dogBytes = thumbnailBytes(tester);
    final dogImageState = tester.state(find.byType(Image));
    await tester.pumpWidget(
        conversationBubble(imageMessage(dogSource, id: 'another-photo')));
    expect(identical(thumbnailBytes(tester), dogBytes), isFalse);
    expect(tester.state(find.byType(Image)), isNot(same(dogImageState)));

    await tester.pumpWidget(conversationBubble({
      'id': 'another-photo',
      'kind': 'recalled',
      'image': message['image']
    }));
    expect(find.byType(Image), findsNothing);
    expect(find.text('对方撤回了一条消息'), findsOneWidget);
    await tester.pumpWidget(
        conversationBubble(imageMessage(dogSource, id: 'another-photo')));
    expect(identical(thumbnailBytes(tester), dogBytes), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待发送图片复用本地字节，服务器确认后使用正式缩略图', (tester) async {
    final message = imageMessage(dogSource)..['_localImageBytes'] = catBytes;
    await tester.pumpWidget(conversationBubble(message));
    expect(thumbnailBytes(tester), same(catBytes));
    for (var i = 0; i < 5; i++) {
      await tester.pumpWidget(conversationBubble({...message}, time: '$i'));
      expect(thumbnailBytes(tester), same(catBytes));
    }
    message.remove('_localImageBytes');
    await tester.pumpWidget(conversationBubble(message));
    expect(thumbnailBytes(tester), chatImageBytes(dogSource));
    expect(identical(thumbnailBytes(tester), catBytes), isFalse);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('坏缩略图安全显示占位，替换正常来源后恢复', (tester) async {
    for (final source in [
      'https://example.invalid/photo.png',
      'data:image/png;base64,broken!',
      'data:image/png;base64,YQ==', // Valid base64, invalid encoded image.
    ]) {
      for (var i = 0; i < 3; i++) {
        await tester
            .pumpWidget(conversationBubble(imageMessage(source), time: '$i'));
        await tester.pumpAndSettle();
      }
      expect(find.text('图片无法显示'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(conversationBubble(imageMessage(catSource)));
    await tester.pumpAndSettle();
    expect(thumbnailBytes(tester), catBytes);
    expect(find.text('图片无法显示'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
