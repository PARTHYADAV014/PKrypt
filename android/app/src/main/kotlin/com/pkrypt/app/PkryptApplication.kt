package com.pkrypt.app

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.lang.ref.WeakReference
import java.util.concurrent.Executors

class PkryptApplication : Application() {

    companion object {
        const val ENGINE_ID = "pkrypt_main_engine"
        private const val SYNC_CHANNEL_NAME = "com.vaultgallery/sync_service"
        private const val NOTIFICATION_REQUEST_CODE = 9021

        private val thumbExecutor = Executors.newSingleThreadExecutor()
        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        private var activeActivityRef: WeakReference<Activity>? = null

        fun setActiveActivity(activity: Activity) {
            activeActivityRef = WeakReference(activity)
        }

        fun clearActiveActivity(activity: Activity) {
            if (activeActivityRef?.get() === activity) {
                activeActivityRef = null
            }
        }

        @Synchronized
        fun getOrCreateEngine(context: Context): FlutterEngine {
            val cache = FlutterEngineCache.getInstance()
            val existing = cache.get(ENGINE_ID)
            if (existing != null) return existing

            val appContext = context.applicationContext
            val engine = FlutterEngine(appContext)
            registerSyncChannel(appContext, engine)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
            cache.put(ENGINE_ID, engine)
            return engine
        }

        private fun registerSyncChannel(appContext: Context, engine: FlutterEngine) {
            MethodChannel(engine.dartExecutor.binaryMessenger, SYNC_CHANNEL_NAME)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "startForegroundSync", "updateForegroundSync" -> {
                            val title = call.argument<String>("title") ?: "Pkrypt Auto-Backup"
                            val text = call.argument<String>("text")
                                ?: "Zero-knowledge background sync active"
                            result.success(startOrUpdateSyncService(appContext, title, text))
                        }

                        "stopForegroundSync" -> {
                            try {
                                val intent = Intent(appContext, VaultSyncForegroundService::class.java).apply {
                                    action = VaultSyncForegroundService.ACTION_STOP
                                }
                                appContext.startService(intent)
                                result.success(true)
                            } catch (_: Exception) {
                                result.success(false)
                            }
                        }

                        "isWifiConnected" -> {
                            result.success(isWifiActive(appContext))
                        }

                        "requestNotificationPermission" -> {
                            if (Build.VERSION.SDK_INT >= 33) {
                                val perm = "android.permission.POST_NOTIFICATIONS"
                                val granted = ContextCompat.checkSelfPermission(appContext, perm) ==
                                    PackageManager.PERMISSION_GRANTED
                                val activity = activeActivityRef?.get()
                                if (!granted && activity != null) {
                                    ActivityCompat.requestPermissions(
                                        activity,
                                        arrayOf(perm),
                                        NOTIFICATION_REQUEST_CODE
                                    )
                                }
                                result.success(granted)
                            } else {
                                result.success(true)
                            }
                        }

                        "openBatteryOptimizationSettings" -> {
                            result.success(openBatterySettingsSafely(appContext))
                        }

                        "extractVideoThumbnail" -> {
                            val path = call.argument<String>("path")
                            val maxWidth = call.argument<Int>("maxWidth") ?: 360
                            if (path.isNullOrBlank()) {
                                result.success(null)
                            } else {
                                thumbExecutor.execute {
                                    val bytes = extractVideoFrameJpeg(path, maxWidth)
                                    mainHandler.post { result.success(bytes) }
                                }
                            }
                        }

                        else -> result.notImplemented()
                    }
                }
        }

        private fun extractVideoFrameJpeg(path: String, maxDim: Int): ByteArray? {
            val retriever = MediaMetadataRetriever()
            return try {
                retriever.setDataSource(path)
                var bitmap: Bitmap? = null
                if (Build.VERSION.SDK_INT >= 27) {
                    bitmap = retriever.getScaledFrameAtTime(
                        1_000_000L,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        maxDim,
                        maxDim
                    ) ?: retriever.getScaledFrameAtTime(
                        0L,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        maxDim,
                        maxDim
                    )
                }
                if (bitmap == null) {
                    bitmap = retriever.getFrameAtTime(
                        1_000_000L,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                    ) ?: retriever.getFrameAtTime(
                        0L,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                    ) ?: retriever.frameAtTime
                }
                if (bitmap == null) return null

                val w = bitmap.width
                val h = bitmap.height
                val finalBmp = if (w > maxDim || h > maxDim) {
                    val scale = maxDim.toFloat() / maxOf(w, h).toFloat()
                    val nw = (w * scale).toInt().coerceAtLeast(1)
                    val nh = (h * scale).toInt().coerceAtLeast(1)
                    val scaled = Bitmap.createScaledBitmap(bitmap, nw, nh, true)
                    if (scaled !== bitmap) bitmap.recycle()
                    scaled
                } else {
                    bitmap
                }

                val out = ByteArrayOutputStream()
                finalBmp.compress(Bitmap.CompressFormat.JPEG, 75, out)
                finalBmp.recycle()
                out.toByteArray()
            } catch (_: Exception) {
                null
            } finally {
                try {
                    retriever.release()
                } catch (_: Exception) {}
            }
        }

        private fun openBatterySettingsSafely(appContext: Context): Boolean {
            val starter: Context = activeActivityRef?.get() ?: appContext
            val needsNewTask = starter !is Activity
            val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            val alreadyIgnoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                pm.isIgnoringBatteryOptimizations(appContext.packageName)
            } else {
                true
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !alreadyIgnoring) {
                try {
                    val popupIntent = Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:${appContext.packageName}")
                    )
                    if (needsNewTask) popupIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    starter.startActivity(popupIntent)
                    return true
                } catch (_: Exception) {}
            }

            try {
                val appInfoIntent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${appContext.packageName}")
                )
                if (needsNewTask) appInfoIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                starter.startActivity(appInfoIntent)
                return true
            } catch (_: Exception) {}

            return try {
                val fallbackIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                if (needsNewTask) fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                starter.startActivity(fallbackIntent)
                true
            } catch (_: Exception) {
                false
            }
        }

        private fun startOrUpdateSyncService(
            appContext: Context,
            title: String,
            text: String
        ): Boolean {
            return try {
                val intent = Intent(appContext, VaultSyncForegroundService::class.java).apply {
                    action = VaultSyncForegroundService.ACTION_START_OR_UPDATE
                    putExtra(VaultSyncForegroundService.EXTRA_TITLE, title)
                    putExtra(VaultSyncForegroundService.EXTRA_TEXT, text)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ContextCompat.startForegroundService(appContext, intent)
                } else {
                    appContext.startService(intent)
                }
                true
            } catch (_: Exception) {
                false
            }
        }

        private fun isWifiActive(appContext: Context): Boolean {
            return try {
                val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val network = cm.activeNetwork ?: return false
                    val caps = cm.getNetworkCapabilities(network) ?: return false
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                } else {
                    @Suppress("DEPRECATION")
                    cm.activeNetworkInfo?.type == ConnectivityManager.TYPE_WIFI
                }
            } catch (_: Exception) {
                true
            }
        }
    }
}