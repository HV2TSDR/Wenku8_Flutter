package org.mewx.wenku8_flutter

import android.content.ContentValues
import android.content.Context
import android.graphics.BitmapFactory
import android.os.Build
import android.provider.MediaStore

/** Keep original encoded pixels; exporting never recompresses a book image. */
internal object BookImageStore {
    data class Image(val bytes: ByteArray, val mime: String, val name: String)
    fun image(bytes: ByteArray?, name: String?): Image {
        require(bytes != null && bytes.size in 16..8 * 1024 * 1024) { "图片大小无效" }
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        val extension = when (options.outMimeType) {
            "image/jpeg" -> "jpg"
            "image/png" -> "png"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            else -> throw IllegalArgumentException("不支持此图片格式")
        }
        require(options.outWidth > 0 && options.outHeight > 0 && options.outWidth.toLong() * options.outHeight <= 80_000_000) { "图片尺寸无效" }
        val stem = (name ?: "文库插图").replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "-").take(96).ifBlank { "文库插图" }
        return Image(bytes, options.outMimeType, "$stem.$extension")
    }

    fun save(context: Context, image: Image) {
        check(Build.VERSION.SDK_INT >= 29)
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, image.name)
            put(MediaStore.Images.Media.MIME_TYPE, image.mime)
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Wenku8")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("无法创建图片")
        try {
            resolver.openOutputStream(uri)?.use { it.write(image.bytes); it.flush() }
                ?: throw IllegalStateException("无法保存图片")
            check(resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null) == 1) { "图片尚未保存完成" }
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }
}
