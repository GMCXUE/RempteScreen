import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/file_transfer.dart';
import 'package:remotescreen/file_transfer_screen.dart';
import 'package:remotescreen/session_manager.dart';

class TransferLocationManager extends SessionManager {
  TransferLocationManager() : super(api: ApiService(baseUrl: 'http://127.0.0.1'));

  @override
  List<FileTransferProgress> get fileHistory => const [
        FileTransferProgress(
            direction: FileTransferDirection.receive,
            id: 1,
            name: '报告.pdf',
            transferred: 1024,
            size: 1024,
            done: true,
            savedPath: '下载/RemoteScreen-Files/报告 (1).pdf'),
        FileTransferProgress(
            direction: FileTransferDirection.receive,
            id: 2,
            name: '未完成.pdf',
            transferred: 0,
            size: 1024,
            done: false),
      ];
}

void main() {
  testWidgets('已完成接收展示实际重名保存位置；系统不能打开时提供可选择的查找路径', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final manager = TransferLocationManager();
    addTearDown(manager.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FileTransferScreen(
                manager: manager,
                devices: const [],
                currentDeviceId: null,
                onConnect: (_, __) async => null))));
    await tester.pumpAndSettle();
    final folder = find.byTooltip('打开所在目录');
    expect(folder, findsOneWidget);
    await tester.ensureVisible(folder);
    await tester.pumpAndSettle();
    expect(find.text('保存位置：下载/RemoteScreen-Files/报告 (1).pdf'), findsOneWidget);
    // Desktop test host cannot launch Android's manager: exercise the real UI
    // error path without depending on a vendor file manager being installed.
    await tester.tap(folder);
    await tester.pumpAndSettle();
    expect(find.text('无法打开文件所在目录'), findsOneWidget);
    expect(find.text('下载/RemoteScreen-Files/报告 (1).pdf'), findsOneWidget);
    expect(find.byType(SelectableText), findsNWidgets(2));
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(folder, findsOneWidget);
  });
}
