package io.replicamedia.replica

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Bundle
import android.text.TextUtils
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import kotlin.math.roundToInt

class SearchVideoActivity : Activity() {
    private var webView: WebView? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val videoId = intent.getStringExtra(EXTRA_VIDEO_ID).orEmpty()
        if (!videoIdPattern.matches(videoId)) {
            finish()
            return
        }
        val origin = "https://$packageName"
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
        }
        val player = WebView(this).apply {
            setBackgroundColor(Color.BLACK)
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                mediaPlaybackRequiresUserGesture = false
                allowFileAccess = false
                allowContentAccess = false
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            }
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                    request.isForMainFrame
            }
        }
        webView = player
        root.addView(player, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(200)))
        root.addView(buildVideoDetails(videoId), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        fun resizePlayer() {
            val width = root.width - root.paddingLeft - root.paddingRight
            val height = root.height - root.paddingTop - root.paddingBottom
            val minimum = dp(200)
            val maximum = (height - dp(118)).coerceAtLeast(minimum)
            val target = (width * 9 / 16).coerceIn(minimum, maximum)
            if (player.layoutParams.height != target) {
                player.layoutParams = player.layoutParams.apply { this.height = target }
            }
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val padding = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout(),
            )
            view.setPadding(padding.left, padding.top, padding.right, padding.bottom)
            resizePlayer()
            insets
        }
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> resizePlayer() }
        setContentView(root)
        player.loadDataWithBaseURL(
            "$origin/",
            """
            <!doctype html>
            <html lang="ko">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="referrer" content="strict-origin-when-cross-origin">
            <style>
              html, body, iframe { margin: 0; width: 100%; height: 100%; background: black; }
              iframe { display: block; border: 0; }
            </style>
            <iframe id="player" title="YouTube 영상" allow="autoplay; encrypted-media"
              src="https://www.youtube.com/embed/$videoId?autoplay=1&amp;playsinline=1&amp;fs=0&amp;enablejsapi=1&amp;origin=$origin"></iframe>
            <script>
              let player;
              function onYouTubeIframeAPIReady() { player = new YT.Player('player'); }
              function pauseVideo() { player?.pauseVideo?.(); }
            </script>
            <script src="https://www.youtube.com/iframe_api"></script>
            </html>
            """.trimIndent(),
            "text/html",
            "UTF-8",
            null,
        )
    }

    private fun buildVideoDetails(videoId: String): ScrollView {
        val dark = intent.getBooleanExtra(EXTRA_DARK_MODE, false)
        val surface = Color.parseColor(if (dark) "#09090B" else "#FFFFFF")
        val primary = Color.parseColor(if (dark) "#FAFAFA" else "#09090B")
        val secondary = Color.parseColor(if (dark) "#A1A1AA" else "#71717A")
        val pill = Color.parseColor(if (dark) "#27272A" else "#F4F4F5")
        val details = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(16), dp(20), dp(20))
        }
        details.addView(TextView(this).apply {
            text = intent.getStringExtra(EXTRA_TITLE)
            setTextColor(primary)
            textSize = 21f
            typeface = Typeface.DEFAULT_BOLD
            ViewCompat.setAccessibilityHeading(this, true)
        })
        val artist = intent.getStringExtra(EXTRA_ARTIST).orEmpty()
        if (artist.isNotBlank()) {
            details.addView(TextView(this).apply {
                text = artist
                setTextColor(secondary)
                textSize = 14f
                maxLines = 2
                ellipsize = TextUtils.TruncateAt.END
                setPadding(0, dp(4), 0, 0)
            })
        }

        val actions = LinearLayout(this).apply {
            setPadding(0, dp(16), 0, 0)
            addView(videoButton("닫기", primary, pill) { finish() })
            addView(
                videoButton("YouTube에서 열기", primary, pill) { openOnYouTube(videoId) },
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                    .apply { marginStart = dp(8) },
            )
        }
        details.addView(actions)
        return ScrollView(this).apply {
            setBackgroundColor(surface)
            addView(details)
        }
    }

    private fun videoButton(label: String, foreground: Int, fill: Int, action: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        setTextColor(foreground)
        minimumHeight = dp(48)
        setPadding(dp(16), dp(8), dp(16), dp(8))
        background = RippleDrawable(
            ColorStateList.valueOf(0x24000000 or (foreground and 0x00FFFFFF)),
            GradientDrawable().apply {
                cornerRadius = dp(24).toFloat()
                setColor(fill)
            },
            null,
        )
        setOnClickListener { action() }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    private fun openOnYouTube(videoId: String) {
        val url = Uri.parse("https://www.youtube.com/watch?v=$videoId")
        try {
            startActivity(Intent(Intent.ACTION_VIEW, url))
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, "YouTube를 열 수 없습니다.", Toast.LENGTH_SHORT).show()
        }
    }

    override fun onResume() {
        super.onResume()
        webView?.onResume()
    }

    override fun onPause() {
        webView?.evaluateJavascript("pauseVideo()", null)
        webView?.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        webView?.let { player ->
            (player.parent as ViewGroup).removeView(player)
            player.destroy()
        }
        webView = null
        super.onDestroy()
    }

    companion object {
        const val EXTRA_VIDEO_ID = "video_id"
        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_DARK_MODE = "dark_mode"
        val videoIdPattern = Regex("[A-Za-z0-9_-]{11}")
    }
}
