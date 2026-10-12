# 消息页布局调整

根据确认的聊天布局草图，桌面消息页使用联系人栏与聊天区两列布局，填满剩余窗口。添加好友改为联系人栏右上角的 +，账号 ID 收进栏底折叠项。取消页面大标题、大按钮和外层卡片留白，仅联系人列表和消息记录内部滚动。发送和好友申请按钮采用局部紧凑尺寸，避免通用 primary 按钮宽度影响布局。

移动端同步采用紧凑的消息/好友切换和右上角 +，空白状态去掉外层卡片及重复添加按钮，提示文案与桌面一致。手机继续使用列表进入独立会话的布局。

验证：桌面 JavaScript 语法检查通过；本地无头浏览器渲染 760、940、1200 × 620，均无内容外层滚动，添加按钮宽 30，页面底部位于窗口底部。移动端 dart format 完成，flutter analyze 仅报告已有 main.dart:19 AudioSessionOptions 实验 API 警告。未运行真实聊天联调，未打包、部署或覆盖安装。

草图：docs/design/desktop-social-layout-sketch.png
桌面实际 HTML/CSS 的本地渲染：docs/design/desktop-social-layout-implemented.png（示例账号和空列表，非已安装应用截图）。

用户随后授权覆盖安装：Mac 测试签名 App 构建成功，覆盖 /Applications/RemoteScreen.app 并启动，旧版备份 /private/tmp/RemoteScreen-before-install-20261011-013958.app。安卓 arm64 release APK 构建成功，无线流式安装失败后改用 --no-streaming，返回 Success，保留应用数据。此次未更新服务端。
