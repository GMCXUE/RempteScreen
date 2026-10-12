import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/account_avatar.dart';

void main() {
  tearDown(clearAvatarProfiles);
  testWidgets(
      'unknown and old account avatars fall back; profile changes update open views',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: AccountAvatar(accountId: 'alice', avatarId: '../unknown'))));
    AssetImage asset() =>
        tester.widget<Image>(find.byType(Image)).image as AssetImage;
    expect(asset().assetName, 'assets/avatars/cat.png');
    rememberAvatar('alice', 'fox');
    await tester.pump();
    expect(asset().assetName, 'assets/avatars/fox.png');
  });
  testWidgets('picker saves the chosen avatar after confirmation',
      (tester) async {
    AvatarSelection? submitted;
    AvatarSelection? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await chooseAccountAvatar(context,
                          current: const AvatarSelection('cat'),
                          save: (id) async {
                        submitted = id;
                        return id;
                      });
                    },
                    child: const Text('更换头像'))))));
    await tester.tap(find.text('更换头像'));
    await tester.pumpAndSettle();
    expect(find.byType(AvatarPicker), findsOneWidget);
    expect(find.text('小狐狸'), findsNothing);
    expect(find.text('默认头像 3'), findsNothing);
    await tester.tap(find.bySemanticsLabel('默认头像 3'));
    await tester.pump();
    expect(submitted, isNull);
    await tester.tap(find.text('保存头像'));
    await tester.pumpAndSettle();
    expect(submitted?.id, 'fox');
    expect(result?.id, 'fox');
    expect(find.byType(AvatarPicker), findsNothing);
  });
  testWidgets('failed save keeps the picker open and allows retry',
      (tester) async {
    int attempts = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AvatarPicker(
                current: const AvatarSelection('dog'),
                save: (_) async {
                  ++attempts;
                  throw Exception('网络不可用');
                }))));
    await tester.tap(find.bySemanticsLabel('默认头像 4'));
    await tester.pump();
    await tester.tap(find.text('保存头像'));
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不可用'), findsOneWidget);
    expect(find.byType(AvatarPicker), findsOneWidget);
    expect(avatarProfiles.value, isEmpty);
    await tester.tap(find.text('保存头像'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });
}
