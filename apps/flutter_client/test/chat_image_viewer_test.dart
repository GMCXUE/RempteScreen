import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/chat_message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('remotescreen/native');
  testWidgets('全屏图片可缩放旋转复位，复制重新读取原图且不重复提交', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var reads = 0, copies = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'copyChatImage') copies++;
      if (call.method == 'clipboardHasSystemFeedback') return false;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final bytes = File('assets/avatars/cat.png').readAsBytesSync();
    await tester.pumpWidget(MaterialApp(home: ChatImageViewer(load: () async {
      reads++;
      return bytes;
    })));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    await tester.tap(find.byTooltip('放大'));
    await tester.pumpAndSettle();
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));
    await tester.tap(find.byTooltip('旋转'));
    await tester.pumpAndSettle();
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
    expect(controller.value.getMaxScaleOnAxis(), 1);
    await tester.tap(find.text('1:1'));
    await tester.pumpAndSettle();
    expect(controller.value.getMaxScaleOnAxis(), greaterThanOrEqualTo(1));
    await tester.tap(find.byTooltip('适应窗口'));
    await tester.pumpAndSettle();
    expect(controller.value.getMaxScaleOnAxis(), 1);
    await tester.tap(find.byTooltip('复制图片'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(copies, 1);
    expect(find.text('图片已复制'), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(320, 720));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets('加载失败可重试，退出后迟到结果不修改页面', (tester) async {
    var fail = true;
    final bytes = File('assets/avatars/cat.png').readAsBytesSync();
    await tester.pumpWidget(MaterialApp(home: ChatImageViewer(load: () async {
      if (fail) throw Exception('网络不可用');
      return bytes;
    })));
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不可用'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsNothing);
    final pending = Completer<Uint8List>();
    await tester.pumpWidget(MaterialApp(
        home: ChatImageViewer(
            key: const ValueKey('next'), load: () => pending.future)));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(bytes);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
