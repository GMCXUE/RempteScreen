# RemoteScreen Android 端

手机 / 平板上的观看端，产出可安装的 APK。

## 为什么是 WebView 壳

Electron 打不了手机包（只能跑 Windows / macOS / Linux），而原生重写一套界面成本很高。
所以这里做成一个极简的 WebView 壳，界面仍然来自服务器上的同一份页面：

- **桌面端、手机浏览器、这个 APK 跑的是同一套代码** —— 改一次界面三端同时生效，不用重新发版
- APK 只有几 MB（对比桌面端 151 MB，因为不用打包整个浏览器内核）
- 没有 AndroidX 依赖，构建快、没有版本冲突

**代价**：应用必须联网才能用。但这个应用本来就需要联网 —— 账号、设备目录、媒体转发全在服务端，
内嵌静态资源的唯一收益是首屏快一点，代价是每次改界面都要重新打包分发。不划算。

## 构建

```bash
./build.sh
```

需要 **JDK 17+** 与 **Android SDK**（`platforms;android-34` + `build-tools;34.0.0`）。
脚本会自己找工具链，缺什么会明确告诉你。

产物：`app/build/outputs/apk/debug/app-debug.apk`

## 安装到手机

1. 把 APK 传到手机（数据线、微信文件传输助手、网盘都可以）
2. 手机上点击安装。首次会提示「未知来源应用」——需要在系统设置里允许，这是侧载的正常流程
3. 装完打开即可，界面和手机浏览器打开服务器页面完全一致

也可以直接用 adb：

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## 已知限制

- **服务端地址写死在 `MainActivity.START_URL`**，换服务器要改代码重新打包。要做成可配置得加一个设置界面。
- **用的是调试签名**，可以直接安装试用，但**不能上架应用商店**，也无法做到覆盖升级（签名不同会被拒绝安装）。
  正式分发需要生成自己的签名证书。
- **`usesCleartextTraffic` 开着**，因为服务端还没有域名与证书。上了 HTTPS 后应当把它删掉。
- 没有后台保活：切到后台或锁屏时，WebView 会被系统限制，连接可能中断。这是壳方案的固有代价，
  要真正后台常驻得做原生媒体栈。
- 没有应用内截图、录屏、通知等原生能力。

## 目录

```
app/src/main/
├── AndroidManifest.xml
├── java/com/remotescreen/app/MainActivity.java   唯一的一个类
└── res/
    ├── values/{strings,colors,themes}.xml
    └── mipmap-*/ic_launcher.png                  由 ../desktop/scripts/make-icons.py 生成
```
