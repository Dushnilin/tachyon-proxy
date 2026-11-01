package org.tachyon.vpn

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Встроенный ContentProvider для передачи скачанного APK обновления
 * системному установщику пакетов Android без сторонних зависимостей.
 */
class ApkFileProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    private fun resolveFile(uri: Uri): File {
        val ctx = context ?: throw FileNotFoundException("Context is null")
        val name = uri.lastPathSegment?.replace("..", "") ?: "tachyon-update.apk"
        val file = File(File(ctx.filesDir, "update"), name)
        if (!file.exists()) {
            throw FileNotFoundException("APK not found: ${file.absolutePath}")
        }
        return file
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val file = resolveFile(uri)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String = "application/vnd.android.package-archive"

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val file = resolveFile(uri)
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(cols, 1)
        val row = cursor.newRow()
        for (col in cols) {
            when (col) {
                OpenableColumns.DISPLAY_NAME -> row.add(file.name)
                OpenableColumns.SIZE -> row.add(file.length())
                else -> row.add(null)
            }
        }
        return cursor
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        const val AUTHORITY = "app.tachyon.tachyon_proxy.apkprovider"
    }
}
