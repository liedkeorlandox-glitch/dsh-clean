package io.github.ccch1mneyyy.dsh_app.storage

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * App-owned storage cleaner. No DSH process, model, network, or shell is used.
 * Every destructive action is restricted to an explicit cache rule or this
 * class's quarantine. Conversations, attachments, plugins and workspace are
 * never candidates.
 */
class StorageCleaner(private val context: Context) {
    private val rootfs = File(context.filesDir, "runtime/rootfs")
    private val trash = File(context.filesDir, "storage-clean/trash")
    private val cancelled = AtomicBoolean(false)

    data class Rule(val id: String, val relative: String, val staleMs: Long = 0)
    data class Candidate(val rule: String, val file: File, var bytes: Long = 0, var files: Long = 0)
    data class Measure(var bytes: Long = 0, var files: Long = 0)

    private val rules = listOf(
        Rule("apt", "var/cache/apt"), Rule("apt", "var/lib/apt/lists"),
        Rule("npm", "root/.npm/_cacache"), Rule("pip", "root/.cache/pip"),
        Rule("yarn", "root/.cache/yarn"), Rule("pnpm", "root/.cache/pnpm"),
        Rule("gradle", "root/.gradle/caches"), Rule("maven", "root/.m2/repository"),
        Rule("dsh-cache", "root/.dsh/cache"),
        Rule("tmp", "tmp", DAY_MS), Rule("var-tmp", "var/tmp", DAY_MS),
    )

    fun cancel() { cancelled.set(true) }

    fun scan(): Map<String, Any?> {
        cancelled.set(false)
        val groups = linkedMapOf<String, Candidate>()
        rules.forEach { rule ->
            checkCancelled()
            val base = File(rootfs, rule.relative)
            if (!base.exists()) return@forEach
            val targets = if (rule.staleMs > 0) base.listFiles()?.toList().orEmpty() else listOf(base)
            targets.forEach { file ->
                if (rule.staleMs == 0L || isStaleTree(file, rule.staleMs)) {
                    val candidate = groups.getOrPut("${rule.id}:${file.path}") {
                        Candidate(rule.id, file)
                    }
                    measure(file, candidate)
                }
            }
        }
        // Other user caches are separate candidates, without double counting
        // pip/yarn/pnpm which have their own rules.
        File(rootfs, "root/.cache").listFiles()?.forEach { file ->
            if (file.name !in setOf("pip", "yarn", "pnpm")) {
                val c = Candidate("user-cache", file)
                measure(file, c)
                groups["user-cache:${file.path}"] = c
            }
        }
        val items = groups.values.filter { it.bytes > 0 }.sortedByDescending { it.bytes }
        return mapOf(
            "schema" to 1,
            "installed" to rootfs.isDirectory,
            "categories" to JSONArray(items.map { item ->
                JSONObject().put("id", item.rule).put("path", relative(item.file))
                    .put("bytes", item.bytes).put("files", item.files)
            }),
            "totalBytes" to items.sumOf { it.bytes },
            "quarantineBytes" to quarantineEntries().sumOf { it.second },
        )
    }

    fun quarantine(paths: List<String>): Map<String, Any?> {
        cancelled.set(false)
        checkCancelled()
        val requested = paths.toSet()
        // Recompute candidates rather than trusting paths supplied by Dart.
        val allowed = scanCandidates().filter { relative(it.file) in requested }
        if (allowed.size != requested.size) throw IOException("Candidate set changed; scan again")
        trash.mkdirs()
        var moved = 0
        var bytes = 0L
        val completed = mutableListOf<Triple<String, File, File>>()
        try {
            allowed.forEach { candidate ->
                checkCancelled()
                val id = UUID.randomUUID().toString()
                val fileDir = File(trash, "files").apply { mkdirs() }
                val infoDir = File(trash, "info").apply { mkdirs() }
                val target = File(fileDir, id)
                val infoFile = File(infoDir, "$id.json")
                if (target.exists()) throw IOException("Quarantine id collision")
                val info = JSONObject().put("path", relative(candidate.file))
                    .put("bytes", candidate.bytes).put("category", candidate.rule)
                    .put("deletedAt", System.currentTimeMillis()).toString()
                // Write metadata first with a unique name, then move the body.
                infoFile.writeText(info)
                if (!candidate.file.renameTo(target)) {
                    infoFile.delete()
                    throw IOException("Cannot quarantine on this filesystem")
                }
                completed += Triple(id, target, candidate.file)
                moved++
                bytes += candidate.bytes
            }
        } catch (e: Exception) {
            // Best-effort rollback keeps a cancelled/failed batch recoverable.
            completed.asReversed().forEach { (id, target, original) ->
                original.parentFile?.mkdirs()
                if (target.renameTo(original)) File(trash, "info/$id.json").delete()
            }
            throw e
        }
        return mapOf("moved" to moved, "bytes" to bytes)
    }

    fun quarantineList(): List<Map<String, Any?>> = quarantineEntries().map { (id, bytes, info) ->
        mapOf("id" to id, "path" to info.optString("path"), "bytes" to bytes,
            "category" to info.optString("category"), "deletedAt" to info.optLong("deletedAt"))
    }

    fun restore(id: String) {
        require(id.matches(Regex("[a-f0-9-]{36}"))) { "Invalid quarantine id" }
        val body = File(trash, "files/$id")
        val infoFile = File(trash, "info/$id.json")
        val info = JSONObject(infoFile.readText())
        val original = safeRootPath(info.getString("path"))
        if (original.exists()) throw IOException("Original path exists")
        original.parentFile?.mkdirs()
        if (!body.renameTo(original)) throw IOException("Restore failed")
        infoFile.delete()
    }

    fun purge(olderThanMs: Long): Map<String, Any?> {
        require(olderThanMs >= DAY_MS) { "Retention must be at least one day" }
        val cutoff = System.currentTimeMillis() - olderThanMs
        var count = 0
        var bytes = 0L
        quarantineEntries().forEach { (id, size, info) ->
            if (info.optLong("deletedAt") <= cutoff) {
                val body = File(trash, "files/$id")
                // Delete data first; a missing info file is recoverable only by id,
                // never by guessing an original path.
                if (!body.exists() || body.deleteRecursively()) {
                    File(trash, "info/$id.json").delete()
                    count++
                    bytes += size
                }
            }
        }
        return mapOf("deleted" to count, "bytes" to bytes)
    }

    private fun scanCandidates(): List<Candidate> {
        val groups = mutableListOf<Candidate>()
        rules.forEach { rule ->
            val base = File(rootfs, rule.relative)
            if (!base.exists()) return@forEach
            val targets = if (rule.staleMs > 0) base.listFiles()?.toList().orEmpty() else listOf(base)
            targets.forEach { file ->
                if (rule.staleMs == 0L || isStaleTree(file, rule.staleMs)) {
                    groups += Candidate(rule.id, file, measuredBytes(file), 0)
                }
            }
        }
        File(rootfs, "root/.cache").listFiles()?.forEach { file ->
            if (file.name !in setOf("pip", "yarn", "pnpm")) groups += Candidate("user-cache", file, measuredBytes(file))
        }
        return groups
    }

    private fun measure(file: File, into: Candidate) {
        if (file.isSymbolicLink()) return // never follow a link out of a cache root
        if (file.isFile) {
            into.bytes += file.length()
            into.files++
        } else file.listFiles()?.forEach { child ->
            checkCancelled()
            measure(child, into)
        }
    }

    private fun measuredBytes(file: File): Long {
        val c = Candidate("", file)
        measure(file, c)
        return c.bytes
    }

    private fun isStaleTree(file: File, staleMs: Long): Boolean {
        val newest = newestMtime(file)
        return newest > 0 && System.currentTimeMillis() - newest >= staleMs
    }

    private fun newestMtime(file: File): Long {
        if (file.isSymbolicLink()) return 0
        var newest = file.lastModified()
        if (file.isDirectory) file.listFiles()?.forEach { newest = maxOf(newest, newestMtime(it)) }
        return newest
    }

    private fun quarantineEntries(): List<QuarantineEntry> {
        val dir = File(trash, "info")
        return dir.listFiles()?.mapNotNull { file ->
            if (!file.name.endsWith(".json")) return@mapNotNull null
            runCatching {
                val id = file.name.removeSuffix(".json")
                val info = JSONObject(file.readText())
                QuarantineEntry(id, info.optLong("bytes"), info)
            }.getOrNull()
        }.orEmpty().sortedByDescending { it.info.optLong("deletedAt") }
    }

    private data class QuarantineEntry(val id: String, val bytes: Long, val info: JSONObject)

    private fun relative(file: File): String = file.canonicalPath.removePrefix(rootfs.canonicalPath).trimStart('/')

    private fun safeRootPath(path: String): File {
        require(!path.startsWith("/") && !path.split('/').contains("..")) { "Invalid original path" }
        val result = File(rootfs, path).canonicalFile
        require(result.path.startsWith(rootfs.canonicalPath + File.separator)) { "Path escapes runtime" }
        return result
    }

    private fun checkCancelled() { if (cancelled.get()) throw IOException("Cancelled") }

    private fun File.isSymbolicLink(): Boolean = try {
        this.canonicalPath != this.absolutePath
    } catch (_: IOException) { true }

    companion object { private const val DAY_MS = 24L * 60 * 60 * 1000 }
}
