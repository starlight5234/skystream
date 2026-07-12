package dev.akash.skystream

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Build
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    private val TV_CHANNEL = "dev.akash.skystream/tv_channel"
    private val PLAYER_CHANNEL = "dev.akash.skystream/external_player"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        



        // Android TV Channel
        MethodChannel(messenger, TV_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "createTvChannel" -> {
                    TvChannelUtils.createTvChannel(this)
                    result.success(null)
                }
                "addPrograms" -> {
                    // Start a background thread or coroutine ideally, but for now simple invocation
                    // The TvUtils methods do ContentProvider ops which should be background, but strict mode might complain. 
                    // Given this is a demo clone, running on UI thread (MethodChannel default) might cause minor frame drop but is simplest.
                    // Ideally use Thread { ... }.start() if heavy.
                    Thread {
                        val channelId = TvChannelUtils.getChannelId(this, getString(R.string.app_name))
                        if (channelId != null) {
                             val items = call.argument<List<Map<String, Any>>>("programs") ?: emptyList()
                             TvChannelUtils.addPrograms(this, channelId, items)
                             runOnUiThread { result.success(null) }
                        } else {
                             // Try to create channel if missing?
                             TvChannelUtils.createTvChannel(this)
                             val newId = TvChannelUtils.getChannelId(this, getString(R.string.app_name))
                             if (newId != null) {
                                  val items = call.argument<List<Map<String, Any>>>("programs") ?: emptyList()
                                  TvChannelUtils.addPrograms(this, newId, items)
                                  runOnUiThread { result.success(null) }
                             } else {
                                  runOnUiThread { result.error("NO_CHANNEL", "Channel not found and creation failed", null) }
                             }
                        }
                    }.start()
                }
                "deleteStoredPrograms" -> {
                    Thread {
                        TvChannelUtils.deleteStoredPrograms(this)
                        runOnUiThread { result.success(null) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        // External Player Channel — uses native Intent to avoid Uri.parse() issues
        MethodChannel(messenger, PLAYER_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "launchVideoInPlayer") {
                val videoUrl = call.argument<String>("url") ?: run {
                    result.error("INVALID_ARGS", "url is required", null)
                    return@setMethodCallHandler
                }
                val packageName = call.argument<String>("package")
                val mimeType = call.argument<String>("mimeType") ?: "video/*"
                val title = call.argument<String>("title")

                try {
                    val uri = if (videoUrl.startsWith("file://") || (videoUrl.startsWith("/") && File(videoUrl).exists())) {
                        val filePath = if (videoUrl.startsWith("file://")) {
                            videoUrl.substring(7)
                        } else {
                            videoUrl
                        }
                        FileProvider.getUriForFile(this, "${applicationContext.packageName}.fileProvider", File(filePath))
                    } else {
                        Uri.parse(videoUrl)
                    }

                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mimeType)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        if (!packageName.isNullOrEmpty()) setPackage(packageName)
                        if (!title.isNullOrEmpty()) {
                            putExtra("title", title)
                            putExtra("android.intent.extra.TITLE", title)
                        }
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: android.content.ActivityNotFoundException) {
                    result.success(false) // Player not installed / not found
                } catch (e: Exception) {
                    result.error("LAUNCH_ERROR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
