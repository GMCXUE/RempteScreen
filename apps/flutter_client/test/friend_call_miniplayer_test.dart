import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/friend_call_miniplayer.dart';

void main() {
  testWidgets('点击小视频返回通话，拖到左右边缘收起，标识只展开', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var returned = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FriendCallMiniPlayer(
      onReturn: () => returned++,
      video: const ColoredBox(color: Colors.blue),
    ))));
    final mini = find.byKey(const ValueKey('friend-call-mini'));
    expect(tester.getSize(mini), const Size(120, 160));
    await tester.tap(mini);
    expect(returned, 1);
    expect(tester.getSize(mini), const Size(120, 160));
    await tester.drag(mini, const Offset(60, 30));
    await tester.pumpAndSettle();
    expect(tester.getSize(mini), const Size(28, 64));
    expect(tester.getTopRight(mini).dx, 390);
    await tester.tap(mini);
    await tester.pumpAndSettle();
    expect(returned, 1, reason: '边缘标识只展开小窗');
    expect(tester.getSize(mini), const Size(120, 160));
    await tester.drag(mini, const Offset(-350, 20));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(mini).dx, 0);
    expect(tester.getSize(mini), const Size(28, 64));
    await tester.tap(mini);
    await tester.pumpAndSettle();
    await tester.tap(mini);
    expect(returned, 2);
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(mini).dy, lessThanOrEqualTo(390));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
