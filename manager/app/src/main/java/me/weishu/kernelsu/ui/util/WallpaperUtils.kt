package me.weishu.kernelsu.ui.util

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.File

object WallpaperUtils {

    private const val WALLPAPER_DIR = "wallpaper"

    /**
     * Copies the picked image into app-private storage so the wallpaper remains
     * available even if the original content URI becomes invalid.
     */
    fun saveWallpaper(context: Context, uri: Uri): String? {
        return try {
            val dir = File(context.filesDir, WALLPAPER_DIR).apply { mkdirs() }
            val extension = resolveExtension(context, uri)
            val target = File(dir, "wallpaper.$extension")
            context.contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            target.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    fun deleteWallpaper(context: Context, path: String?) {
        if (path.isNullOrBlank()) return
        runCatching {
            File(path).delete()
            // Only succeeds when the directory is already empty.
            File(context.filesDir, WALLPAPER_DIR).delete()
        }
    }

    /**
     * Decodes a bitmap with an inSampleSize chosen from the requested bounds, to
     * avoid loading the full resolution into memory.
     */
    fun decodeSampledBitmap(path: String, reqWidth: Int, reqHeight: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        var sampleSize = 1
        while (bounds.outWidth / (sampleSize * 2) >= reqWidth ||
            bounds.outHeight / (sampleSize * 2) >= reqHeight
        ) {
            sampleSize *= 2
        }

        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
        }
        return BitmapFactory.decodeFile(path, options)
    }

    private fun resolveExtension(context: Context, uri: Uri): String {
        return when (context.contentResolver.getType(uri)) {
            "image/png" -> "png"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            else -> "jpg"
        }
    }
}
