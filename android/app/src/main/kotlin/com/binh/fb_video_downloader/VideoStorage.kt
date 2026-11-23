package com.binh.fb_video_downloader

import android.content.ContentValues
import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.net.Uri
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.OutputStream

internal class VideoStorage(private val app: Context) {
    class Failure(message: String) : IOException(message)

    private val resolver = app.contentResolver
    private val journal = app.getSharedPreferences("facebook_video_exports", Context.MODE_PRIVATE)
    private val authority = "${app.packageName}.video.files"

    fun folderLabel(tree: Uri): String {
        val id = DocumentsContract.getTreeDocumentId(tree)
        val document = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        return resolver.query(document, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
            ?: id.substringAfterLast('/').substringAfter(':')
    }

    fun inspect(path: String): Map<String, Boolean> {
        val media = MediaExtractor()
        var video = false
        var audio = false
        var encrypted = false
        return try {
            media.setDataSource(path)
            encrypted = media.drmInitData != null || !media.psshInfo.isNullOrEmpty()
            for (i in 0 until media.trackCount) {
                val type = media.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (!type.startsWith("video/") && !type.startsWith("audio/")) continue
                media.selectTrack(i)
                if (media.sampleTrackIndex != -1) {
                    if (type.startsWith("video/")) video = true else audio = true
                    encrypted = encrypted || media.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED != 0
                }
                media.unselectTrack(i)
            }
            mapOf("video" to video, "audio" to audio, "encrypted" to encrypted)
        } catch (_: Exception) {
            mapOf("video" to video, "audio" to audio, "encrypted" to encrypted)
        } finally {
            media.release()
        }
    }

    private data class Target(val uri: Uri, val path: String? = null, val mediaStore: Boolean = false)

    fun forget(id: String): Any? {
        journal.edit().remove(id).commit()
        return null
    }

    @Synchronized
    fun recover(id: String): Map<String, String?>? {
        val entry = journal.getString(id, null)?.let { JSONObject(it) } ?: return null
        val uri = Uri.parse(entry.getString("uri"))
        val path = entry.optString("path").ifEmpty { null }
        val mediaStore = entry.optBoolean("mediaStore")
        val result = mapOf("uri" to uri.toString(), "warning" to entry.optString("warning").ifEmpty { null })
        if (entry.optBoolean("done")) return result
        val pending = if (mediaStore && Build.VERSION.SDK_INT >= 29) {
            resolver.query(uri, arrayOf(MediaStore.MediaColumns.IS_PENDING), null, null, null)
                ?.use { cursor -> if (cursor.moveToFirst()) cursor.getInt(0) != 0 else null }
        } else null
        val expected = entry.getLong("bytes")
        val size = if (path != null) File(path).let { if (it.isFile) it.length() else -1 }
            else try {
                resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1
            } catch (_: java.io.FileNotFoundException) { -1 }
        if (entry.optBoolean("copied") || size == expected) {
            if (pending == true && Build.VERSION.SDK_INT >= 29) publish(uri)
            return result
        }
        remove(Target(uri, path, mediaStore))
        forget(id)
        return null
    }

    @Synchronized
    fun export(source: String, name: String, id: String, destination: String?): Map<String, String?> {
        try {
            recover(id)?.let { return it }
            val file = File(source)
            val size = file.length()
            if (!file.isFile || size == 0L) throw Failure("File video tạm không còn trên thiết bị.")
            val fallback = "Không ghi được vào thư mục đã chọn. Video đã lưu vào Downloads."
            if (!destination.isNullOrEmpty()) {
                var target: Target? = null
                try {
                    target = if (destination.startsWith("content://")) {
                        createDocument(Uri.parse(destination), name)
                    } else {
                        val path = File(destination)
                        if (!path.isDirectory) throw IOException()
                        createFile(path, name)
                    }
                    return write(target, file, size, id, null)
                } catch (e: Exception) {
                    if (isNoSpace(e)) throw e
                    if (target != null) remove(target)
                    forget(id)
                }
            }

            var target: Target? = null
            try {
                target = if (Build.VERSION.SDK_INT >= 29) createMediaStore(name)
                    else createFile(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                        .apply { mkdirs() }, name)
                return write(target, file, size, id, if (destination != null) fallback else null)
            } catch (e: Exception) {
                if (isNoSpace(e)) throw e
                if (target != null) remove(target)
                forget(id)
            }
            val privateDir = File(app.filesDir, "exported-videos").apply { mkdirs() }
            return write(createFile(privateDir, name), file, size, id,
                "Không ghi được vào thư mục lưu/Downloads. Video nằm trong bộ nhớ riêng của ứng dụng.")
        } catch (e: Exception) {
            if (e is Failure) throw e
            if (isNoSpace(e)) throw Failure("Không đủ dung lượng lưu trữ video.")
            throw Failure("Không lưu được video. Kiểm tra quyền thư mục và dung lượng còn trống.")
        }
    }

    private fun isNoSpace(error: Throwable): Boolean =
        generateSequence(error) { it.cause }.any {
            it is android.system.ErrnoException && it.errno == android.system.OsConstants.ENOSPC ||
                it.message?.contains("ENOSPC") == true
        }

    private fun copy(file: File, output: OutputStream) {
        output.use { target -> file.inputStream().use { it.copyTo(target, 128 * 1024) } }
    }

    private fun write(target: Target, file: File, size: Long, id: String,
        warning: String?): Map<String, String?> {
        val entry = JSONObject().put("uri", target.uri.toString()).put("path", target.path)
            .put("bytes", size).put("warning", warning).put("mediaStore", target.mediaStore)
        fun save() {
            if (!journal.edit().putString(id, entry.toString()).commit()) throw IOException()
        }
        try {
            save()
            val output = if (target.path != null) File(target.path).outputStream()
                else resolver.openOutputStream(target.uri, "w") ?: throw IOException()
            copy(file, output)
            entry.put("copied", true)
            save()
            if (target.mediaStore && Build.VERSION.SDK_INT >= 29) {
                publish(target.uri)
            }
            entry.put("done", true)
            save()
            return mapOf("uri" to target.uri.toString(), "warning" to warning)
        } catch (e: Exception) {
            remove(target)
            forget(id)
            throw e
        }
    }

    private fun createDocument(tree: Uri, name: String): Target {
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val existing = resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null)?.use { cursor ->
                buildSet<String> {
                    while (cursor.moveToNext()) {
                        cursor.getString(0)?.let { add(it) }
                    }
                }
            }
            ?: throw IOException()
        val unique = generateSequence(0) { it + 1 }.map { numbered(name, it) }
            .first { it !in existing }
        val result = DocumentsContract.createDocument(resolver, root, "video/mp4", unique) ?: throw IOException()
        return Target(result)
    }

    private fun createFile(directory: File, name: String): Target {
        for (index in 0..10000) {
            val file = File(directory, numbered(name, index))
            val uri = FileProvider.getUriForFile(app, authority, file)
            if (file.createNewFile()) return Target(uri, file.absolutePath)
        }
        throw IOException()
    }

    private fun numbered(name: String, index: Int): String =
        if (index == 0) name else "${name.removeSuffix(".mp4")} ($index).mp4"

    @android.annotation.TargetApi(29)
    private fun publish(uri: Uri) {
        check(resolver.update(uri, ContentValues().apply {
            put(MediaStore.MediaColumns.IS_PENDING, 0)
        }, null, null) == 1)
    }

    @android.annotation.TargetApi(29)
    private fun createMediaStore(name: String): Target {
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }) ?: throw IOException()
        return Target(uri, mediaStore = true)
    }

    private fun remove(target: Target) {
        if (target.path != null) {
            val file = File(target.path)
            if (file.exists() && !file.delete()) throw IOException()
        } else {
            delete(target.uri.toString())
        }
    }

    fun delete(value: String): Any? {
        val uri = Uri.parse(value)
        if (DocumentsContract.isDocumentUri(app, uri)) {
            if (!DocumentsContract.deleteDocument(resolver, uri) &&
                resolver.query(uri, null, null, null, null)?.use { it.moveToFirst() } == true) {
                throw Failure("Không có quyền xóa video trong thư mục này.")
            }
        } else {
            resolver.delete(uri, null, null)
        }
        return null
    }
}
