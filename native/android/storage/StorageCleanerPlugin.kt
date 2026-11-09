package io.github.ccch1mneyyy.dsh_app.storage

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Local-only storage API. It works with the AI engine stopped or uninstalled. */
class StorageCleanerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var cleaner: StorageCleaner
    private val worker = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cleaner = StorageCleaner(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, "dsh/storage_cleaner")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        worker.execute {
            try {
                val value = when (call.method) {
                    "scan" -> cleaner.scan()
                    "quarantine" -> cleaner.quarantine(call.argument<List<String>>("paths").orEmpty())
                    "quarantineList" -> cleaner.quarantineList()
                    "restore" -> cleaner.restore(call.argument<String>("id") ?: "").let { mapOf("restored" to true) }
                    "purge" -> cleaner.purge(call.argument<Number>("olderThanMs")?.toLong() ?: DAY)
                    "cancel" -> cleaner.cancel().let { mapOf("cancelled" to true) }
                    else -> null
                }
                if (value == null) result.notImplemented() else result.success(value)
            } catch (e: Exception) {
                result.error("storage_clean_failed", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        cleaner.cancel()
        worker.shutdownNow()
    }

    companion object { private const val DAY = 24L * 60 * 60 * 1000 }
}
