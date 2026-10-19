package org.mewx.wenku8_flutter

import android.content.Context
import android.graphics.Bitmap
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.rendering.PDFRenderer
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.cos.COSDictionary
import java.io.File

internal class BookPdfImport(private val context: Context, private val root: File) {
    private fun verifyImages(resources: PDResources?, visited: MutableSet<COSDictionary>) {
        if (resources == null || !visited.add(resources.cosObject)) return
        for (name in resources.xObjectNames) {
            val item = resources.getXObject(name)
            if (item is PDImageXObject) {
                val filters = item.cosObject.getDictionaryObject(COSName.FILTER)
                val jpx = COSName.getPDFName("JPXDecode")
                val containsJpx = filters == jpx || filters is COSArray && (0 until filters.size()).any { filters.getObject(it) == jpx }
                require(!containsJpx) { "此 PDF 使用 JPEG2000 图片，暂不支持；请转换为 EPUB 后导入" }
            } else if (item is PDFormXObject) verifyImages(item.resources, visited)
        }
    }
    fun read(source: File, writer: BookEpubWriter) {
        PDFBoxResourceLoader.init(context.applicationContext)
        val memory = MemoryUsageSetting.setupTempFileOnly().setTempDir(root)
        PDDocument.load(source, memory).use { document ->
            require(!document.isEncrypted && document.currentAccessPermission.canExtractContent()) { "不支持加密或禁止内容提取的 PDF" }
            require(document.numberOfPages in 1..10000) { "PDF 页数无效或超过 10000 页" }
            document.documentInformation.title?.trim()?.takeIf { it.isNotEmpty() }?.let { writer.title = it.take(2048) }
            writer.author = document.documentInformation.author?.take(2048) ?: ""
            val stripper = PDFTextStripper().apply { sortByPosition = true }
            val renderer = PDFRenderer(document)
            val imageFile = File.createTempFile("pdf-", ".jpg", root)
            try {
                fun image(bitmap: Bitmap, key: String) {
                    try {
                        imageFile.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 88, it) }
                        imageFile.inputStream().use { writer.resource(key, "jpg", it) }
                        writer.image(key, "width:${bitmap.width}px")
                    } finally { bitmap.recycle() }
                }
                for (index in 0 until document.numberOfPages) {
                    verifyImages(document.getPage(index).resources,
                        java.util.Collections.newSetFromMap(java.util.IdentityHashMap<COSDictionary, Boolean>()))
                    writer.heading("第 ${index + 1} 页")
                    stripper.startPage = index + 1; stripper.endPage = index + 1
                    val text = stripper.getText(document).trim()
                    if (text.isBlank()) {
                        val page = document.getPage(index).cropBox
                        val scale = minOf(120f / 72f, 1800f / maxOf(page.width, page.height))
                        image(renderer.renderImage(index, scale), "page-$index")
                    } else {
                        text.lineSequence().forEach(writer::text)
                        val resources = document.getPage(index).resources
                        for (name in resources.xObjectNames) {
                            val item = resources.getXObject(name)
                            if (item is PDImageXObject) {
                                require(item.width.toLong() * item.height <= 24000000) { "PDF 中的图片尺寸过大，请压缩原书后导入" }
                                image(item.image, "page-$index-${name.name}")
                            }
                        }
                    }
                }
            } finally { imageFile.delete() }
        }
    }
}
