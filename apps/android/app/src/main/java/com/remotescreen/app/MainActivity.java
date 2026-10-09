package com.remotescreen.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

/**
 * 极简 WebView 壳。
 *
 * 界面全部来自服务器上的同一份页面 —— 桌面端、手机浏览器与这个 APK 跑的是同一套代码，
 * 改一次界面三端同时生效，不用重新打包分发。
 *
 * 为什么不做成内嵌静态资源：这个应用本来就必须联网才能用（账号、设备目录、媒体转发都在服务端），
 * 内嵌资源的唯一收益是首屏快一点，代价是每次改界面都要重新发版。不划算。
 */
public class MainActivity extends Activity {

    /** 服务端地址。换成域名后这里要一并改，并且应当同时改成 https。 */
    private static final String START_URL = "http://91.208.104.182/viewer/";

    private FrameLayout rootLayout;
    private WebView webView;
    private RemoteChromeClient chromeClient;

    private View fullscreenView;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        rootLayout = new FrameLayout(this);
        webView = new WebView(this);

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        // localStorage 里存着账号令牌与服务器地址，必须开
        settings.setDomStorageEnabled(true);
        // 观看端是自动播放画面，不能要求先有点击手势
        settings.setMediaPlaybackRequiresUserGesture(false);
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);

        webView.setWebViewClient(new WebViewClient());

        chromeClient = new RemoteChromeClient();
        webView.setWebChromeClient(chromeClient);

        rootLayout.addView(webView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        setContentView(rootLayout);

        // 长时间观看时不要因为无操作而息屏
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        if (savedInstanceState == null) {
            webView.loadUrl(START_URL);
        } else {
            // 旋转屏幕后恢复现场，避免重新加载导致断流
            webView.restoreState(savedInstanceState);
        }
    }

    /** 承载网页里的「全屏」按钮：WebView 会用自定义视图覆盖整个窗口。 */
    private class RemoteChromeClient extends WebChromeClient {

        private WebChromeClient.CustomViewCallback callback;

        @Override
        public void onShowCustomView(View view, CustomViewCallback viewCallback) {
            if (fullscreenView != null) {
                viewCallback.onCustomViewHidden();
                return;
            }
            fullscreenView = view;
            callback = viewCallback;

            rootLayout.addView(view, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT));
            webView.setVisibility(View.GONE);

            getWindow().getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION);
        }

        @Override
        public void onHideCustomView() {
            if (fullscreenView == null) return;

            rootLayout.removeView(fullscreenView);
            fullscreenView = null;
            webView.setVisibility(View.VISIBLE);

            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_VISIBLE);

            if (callback != null) {
                callback.onCustomViewHidden();
                callback = null;
            }
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        webView.saveState(outState);
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        // 全屏时先退出全屏，而不是直接退出应用
        if (fullscreenView != null) {
            chromeClient.onHideCustomView();
            return;
        }
        if (webView.canGoBack()) {
            webView.goBack();
            return;
        }
        super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        // 不销毁会泄漏一整个 WebView 及其渲染进程
        if (webView != null) {
            rootLayout.removeView(webView);
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
