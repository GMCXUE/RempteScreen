import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/file_transfer.dart';
import 'package:remotescreen/file_transfer_history.dart';

class HistoryApi extends ApiService {
  HistoryApi() : super(baseUrl: 'http://127.0.0.1');
  final calls = <String?>[];
  bool fail = false;
  @override
  Future<Map<String, dynamic>> fileTransferHistory({String? before}) async {
    calls.add(before);
    if (fail) throw Exception('offline');
    return {'items': [{
      'id': before ?? '2', 'name': before == null ? '合同.pdf' : '旧文件.zip',
      'size': 52428800, 'createdAt': 1700000000000,
      'senderName': '甲', 'senderId': '123', 'senderDeviceName': '甲电脑', 'senderDeviceId': '111111111',
      'recipientName': '乙', 'recipientId': '456', 'recipientDeviceName': '乙手机', 'recipientDeviceId': '222222222',
      'status': before == null ? 'completed' : 'unconfirmed',
    }], 'next': before == null ? '2' : null};
  }
}

void main() {
  test('50 MB exact boundary is allowed; oversize and invalid sizes rejected', () {
    expect(transferFileSizeError(0), isNull);
    expect(transferFileSizeError(maxTransferFileBytes), isNull);
    expect(transferFileSizeError(maxTransferFileBytes+1), transferFileTooLarge);
    expect(transferFileSizeError(-1), '文件大小无效');
  });
  testWidgets('历史展示双方账号设备，支持分页重试，不提供下载', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = HistoryApi();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: FileTransferHistory(api: api)))));
    await tester.pumpAndSettle();
    expect(find.text('合同.pdf'), findsOneWidget);
    expect(find.textContaining('甲电脑'), findsOneWidget);
    expect(find.textContaining('乙手机'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('下载'), findsNothing);
    await tester.tap(find.text('加载更早记录'));
    await tester.pumpAndSettle();
    expect(api.calls, [null, '2']);
    expect(find.text('旧文件.zip'), findsOneWidget);
    expect(find.text('未确认完成'), findsOneWidget);
    api.fail = true;
    await tester.tap(find.byTooltip('刷新传输历史'));
    await tester.pumpAndSettle();
    expect(find.text('传输历史加载失败，请重试'), findsOneWidget);
    expect(find.text('合同.pdf'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.byTooltip('刷新传输历史'));
    await tester.pumpAndSettle();
    expect(find.text('传输历史加载失败，请重试'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
