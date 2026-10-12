package com.remotescreen.remotescreen

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.SurfaceTexture
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.utils.EglUtils
import org.webrtc.EglRenderer
import org.webrtc.EglBase
import org.webrtc.GlRectDrawer
import org.webrtc.VideoTrack

/** The subscribed track stays alive; opening/docking changes only its presentation. */
class RemoteVideoOverlay(context: Context, private val onReturn: (String?, String?) -> Unit) {
    private val context = context.applicationContext
    private val windows = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private var root: FrameLayout? = null
    private var placeholder: TextView? = null
    private var renderer: EglRenderer? = null
    private var track: VideoTrack? = null
    private var owner: String? = null
    private var dismissedSession: String? = null
    private var returnCallId: String? = null
    private var returnAccountId: String? = null
    private var isDocked = false
    private var voice = false
    private var peerName = ""
    private var acceptedAt: Long? = null
    private val clock = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            if (root == null) return
            if (voice) {
                val seconds = acceptedAt?.let { ((System.currentTimeMillis() - it) / 1000).coerceAtLeast(0) } ?: 0L
                placeholder?.text = "$peerName\n${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
            }
            clock.postDelayed(this, 1000)
        }
    }

    fun update(sessionId: String, trackId: String?, manual: Boolean = false,
               visible: Boolean = trackId != null, callId: String? = null, accountId: String? = null,
               kind: String = "video", peerName: String? = null, acceptedAt: Long? = null): Boolean {
        if (!visible) {
            if (owner != sessionId) return false
            dismiss(); owner = null; dismissedSession = null
            return false
        }
        if (owner != sessionId) { dismiss(); dismissedSession = null }
        val nextVoice = kind == "voice"
        if (voice != nextVoice) dismiss()
        voice = nextVoice; this.peerName = peerName ?: "语音通话"; this.acceptedAt = acceptedAt
        owner = sessionId
        returnCallId = callId; returnAccountId = accountId
        if (manual) dismissedSession = null
        if (dismissedSession == sessionId) return false
        if (!Settings.canDrawOverlays(context)) { dismiss(); return false }
        val next = (if (voice) null else trackId)?.let { FlutterWebRTCPlugin.sharedSingleton?.getRemoteTrack(it) as? VideoTrack }
        if (root == null) create(callId != null)
        if (track !== next) {
            renderer?.let { track?.removeSink(it) }
            track = next
            renderer?.let { next?.addSink(it) }
        }
        placeholder?.visibility = if (next == null && !isDocked) View.VISIBLE else View.GONE
        return true
    }

    private fun create(friendCall: Boolean) {
        val density = context.resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()
        fun screenWidth() = context.resources.displayMetrics.widthPixels
        fun screenHeight() = context.resources.displayMetrics.heightPixels
        val placement = VideoOverlayPlacement(dp(if (voice) 104 else if (friendCall) 120 else 180), dp(if (voice) 112 else if (friendCall) 160 else 135), dp(28), dp(64))
        placement.move(screenWidth() - placement.width - dp(16), dp(60), screenWidth(), screenHeight())
        val view = FrameLayout(context).apply {
            background = GradientDrawable().apply { setColor(Color.rgb(23, 32, 42)); cornerRadius = dp(16).toFloat() }
            clipToOutline = true; elevation = dp(6).toFloat()
        }
        val video = EglRenderer("RemoteScreenCallOverlay")
        video.init(EglUtils.getRootEglBaseContext(), EglBase.CONFIG_PLAIN, GlRectDrawer())
        video.setMirror(true)
        val videoView = TextureView(context).apply { isOpaque = false }
        videoView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                video.setLayoutAspectRatio(width.toFloat() / height.coerceAtLeast(1)); video.createEglSurface(surface)
            }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
                video.setLayoutAspectRatio(width.toFloat() / height.coerceAtLeast(1))
            }
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                val released = java.util.concurrent.CountDownLatch(1)
                video.releaseEglSurface { released.countDown() }; released.await()
                return true
            }
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
        }
        val empty = TextView(context).apply {
            text = if (voice) peerName else "视频通话"; gravity = Gravity.CENTER; setTextColor(Color.LTGRAY); textSize = 12f
            maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(dp(8), dp(12), dp(8), dp(12))
            if (voice) {
                setCompoundDrawablesWithIntrinsicBounds(0, R.drawable.ic_call_voice, 0, 0)
                compoundDrawablePadding = dp(8)
            }
            setBackgroundColor(Color.rgb(23, 32, 42))
        }
        val handle = TextView(context).apply {
            gravity = Gravity.CENTER; setTextColor(Color.WHITE); textSize = 28f; visibility = View.GONE
        }
        view.addView(videoView, FrameLayout.LayoutParams(-1, -1))
        view.addView(empty, FrameLayout.LayoutParams(-1, -1))
        view.addView(handle, FrameLayout.LayoutParams(-1, -1))
        val touch = View(context).apply { isClickable = true; isFocusable = true }
        view.addView(touch, FrameLayout.LayoutParams(-1, -1))
        val params = WindowManager.LayoutParams(placement.width, placement.height,
            if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.START; x = placement.x; y = placement.y
        }
        fun applyPlacement() {
            params.width = placement.currentWidth; params.height = placement.currentHeight
            params.x = placement.x; params.y = placement.y
            val docked = placement.edge != 0
            isDocked = docked
            videoView.visibility = if (docked) View.GONE else View.VISIBLE
            empty.visibility = if (!docked && track == null) View.VISIBLE else View.GONE
            handle.visibility = if (docked) View.VISIBLE else View.GONE
            handle.text = if (placement.edge < 0) "›" else "‹"
            touch.contentDescription = if (docked) "展开通话悬浮窗" else "通话中，点击返回，拖到边缘收起"
            (view.background as GradientDrawable).cornerRadius = dp(if (docked) 12 else 16).toFloat()
            windows.updateViewLayout(view, params)
        }
        touch.setOnClickListener {
            if (placement.edge != 0) {
                placement.expand(screenWidth(), screenHeight(), dp(16)); applyPlacement()
            } else {
                dismissedSession = owner
                val id = returnCallId; val account = returnAccountId
                try { onReturn(id, account); dismiss() }
                catch (_: Exception) { dismissedSession = null }
            }
        }
        var startX = 0; var startY = 0; var touchX = 0f; var touchY = 0f; var moved = false
        val slop = ViewConfiguration.get(context).scaledTouchSlop
        touch.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { moved = false; startX = placement.x; startY = placement.y; touchX = event.rawX; touchY = event.rawY }
                MotionEvent.ACTION_MOVE -> {
                    if (kotlin.math.hypot(event.rawX - touchX, event.rawY - touchY) > slop) moved = true
                    if (moved) {
                        placement.move(startX + (event.rawX - touchX).toInt(), startY + (event.rawY - touchY).toInt(), screenWidth(), screenHeight())
                        applyPlacement()
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (moved) { placement.finishDrag(screenWidth(), screenHeight(), dp(24)); applyPlacement() }
                    else touch.performClick()
                }
                MotionEvent.ACTION_CANCEL -> moved = false
            }
            true
        }
        try {
            windows.addView(view, params)
            root = view; placeholder = empty; renderer = video
            touch.contentDescription = "通话中，点击返回，拖到边缘收起"
            clock.post(tick)
        } catch (error: Exception) { video.release(); throw error }
    }

    fun dismiss() {
        clock.removeCallbacks(tick)
        val video = renderer; renderer = null
        try { video?.let { track?.removeSink(it) } } catch (_: Exception) {}
        track = null
        root?.let { try { windows.removeViewImmediate(it) } catch (_: Exception) {} }
        root = null; placeholder = null
        isDocked = false
        video?.release()
    }
}
