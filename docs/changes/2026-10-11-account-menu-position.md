# 左上角账号入口

- 桌面端移除主侧栏顶部的 RemoteScreen 标识，将头像、昵称与下拉菜单整体移到该位置。聊天区右上角取消账号入口，并移除为它预留的间距。
- 原有个人资料、更换头像、退出登录入口保留。昵称过长时省略；账号菜单支持键盘打开、Escape 收起与点击外部收起。
- 移动端主页面同步提供左上角头像菜单，使用相同的三个账号操作，个人资料进入“我的”资料页，页面标题与右侧刷新保留。移动端“我的设备”子页面仍显示返回按钮，这是手机导航的布局差异。
- 用户随后授权三端覆盖安装，记录见下文。

验证：桌面 JavaScript 语法检查通过；本地模拟数据预览确认账号入口位于侧栏左上角，下拉菜单可用键盘或鼠标开合，740/820/1000 像素宽度与长昵称均未溢出。移动端相关文件静态分析通过。

## 覆盖安装（2026-10-11）

- 发布标记：`account-menu-20261011-221049`。
- Mac 已覆盖 `/Applications/RemoteScreen.app` 并启动，PID 3171。构建、安装后的签名验证均通过，沿用 ad hoc 测试签名；程序 SHA-256：`1dc78f24be19ce3507adcc5cb05b65a7ebc1ec65deba68e8f2da90d927916be7`。旧版备份 `/private/tmp/RemoteScreen-before-account-menu-20261011-221049.app`。
- 安卓已通过原无线调试覆盖并启动，PID 18441，MessagingService 与 RequestWatchService 均在运行。实际 APK SHA-256：`79f99f13840a981e74ca2e498900312cc947136c604ac548bf90531986e35d76`，与构建产物一致，新旧签名证书匹配。更新时间 22:13:11，首次安装时间保持 2026-10-08 16:49:21。
- 安卓构建参数 `--build-number 2003`，arm64 包实际 `versionCode=4003`；后续构建编号不得低于 2003。新包 `/private/tmp/RemoteScreen-account-menu-20261011-221049.apk`，旧包备份 `/private/tmp/RemoteScreen-before-account-menu-20261011-221049.apk`。
- Windows 沿用已授权的 `codex/windows-client` 分支，仅同步本次三个桌面界面文件，提交 `18ce87eda1147454b44061a067ea2893a8f48077`。[Actions 38146196776](https://github.com/GMCXUE/RempteScreen/actions/runs/38146196776) 构建成功。产物 ID `11705377494`，下载包 SHA-256 与 GitHub 记录一致：`fbe301c999584693a8d41a3c4c1b44a00f25cb8286efb534846443bc0108b2d3`；安装程序 SHA-256：`52dfe329c7df1420615ec05940a53ef2f90bd318bd57c7179c9d0c851ffa7886`。
- Windows 已覆盖 `E:\新建文件夹 (2)\RemoteScreen`，安装程序退出码 0，实际程序 SHA-256：`133d867d57130cc61800e8e6e33cad7630ff0f75b598c1b1b1f6a7630701b290`。已在用户桌面启动，PID 29252、会话 1；临时启动任务已移除。旧程序备份 `C:\Users\ZHY.04\RemoteScreenBackups\before-account-menu-20261011-221049`。
- 覆盖保留账号、设置与聊天数据，未进行真实设备间业务测试。
