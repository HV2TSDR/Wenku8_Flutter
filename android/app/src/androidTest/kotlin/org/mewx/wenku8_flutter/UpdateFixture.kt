package org.mewx.wenku8_flutter

import android.content.Context
import android.content.Intent
import android.os.Bundle
import java.io.File

/** Real PackageManager/FileProvider checks; never opens an installer or user data. */
object UpdateFixture {
    fun run(context: Context, results: Bundle) {
        check(context.packageName.endsWith(".render_probe"))
        val packages = UpdatePackages(context)
        val source = File(context.filesDir, "update-fixtures")
        val root = File(context.cacheDir, "updates").apply { mkdirs() }
        val legacy = File(root, "update.apk")
        val attempts = mutableListOf<File>()
        var checks = 0
        fun rejected(action: () -> Unit) {
            check(runCatching(action).exceptionOrNull() is IllegalArgumentException)
            checks++
        }
        fun uriBuild(update: VerifiedUpdate): Long {
            val intent = packages.installIntent(update)
            check(intent.action == Intent.ACTION_VIEW)
            check(intent.type == "application/vnd.android.package-archive")
            check(intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
            check(intent.clipData!!.getItemAt(0).uri == intent.data)
            val copy = File(source, "uri-copy.apk")
            context.contentResolver.openInputStream(intent.data!!)!!.use { input ->
                copy.outputStream().use { input.copyTo(it) }
            }
            @Suppress("DEPRECATION")
            val info = context.packageManager.getPackageArchiveInfo(copy.path, 0)!!
            copy.delete()
            check(info.packageName == context.packageName)
            return packages.code(info)
        }
        try {
            File(source, "36.apk").copyTo(legacy, overwrite = true)
            check(packages.inspect(legacy.path, "0.3.4", 36).build == 36L); checks++
            val first = packages.forInstall(legacy.path, "0.3.4", 36)
            attempts += first.file.parentFile!!
            check(first.file != legacy && uriBuild(first) == 36L); checks++
            File(source, "37.apk").copyTo(legacy, overwrite = true)
            val second = packages.forInstall(legacy.path, "0.3.5", 37)
            attempts += second.file.parentFile!!
            check(packages.installIntent(first).data != packages.installIntent(second).data); checks++
            check(uriBuild(first) == 36L && uriBuild(second) == 37L); checks++
            check(packages.forInstall(first.file.path, "0.3.4", 36).file == first.file); checks++
            rejected { packages.inspect(first.file.path, "0.3.5", 36) }
            rejected { packages.inspect(first.file.path, "0.3.4", 37) }
            val folder = File(root, "package-native-fixture").apply { mkdirs() }
            attempts += folder
            val ready = File(folder, "update.apk")
            File(context.applicationInfo.sourceDir).copyTo(ready, overwrite = true)
            rejected { packages.inspect(ready.path, packages.installed().versionName!!) }
            File(source, "other.apk").copyTo(ready, overwrite = true)
            rejected { packages.inspect(ready.path, "0.3.4", 36) }
            ready.writeBytes(byteArrayOf(1, 2, 3))
            rejected { packages.inspect(ready.path, "0.3.4", 36) }
            rejected { packages.inspect(File(source, "36.apk").path, "0.3.4", 36) }
            results.putInt("checks", checks)
            results.putString("stream", "UPDATE_FIXTURE_VERIFIED=$checks;native-builds=36,37;immutable-content-uris=true;legacy-compatible=true\n")
        } finally {
            legacy.delete()
            attempts.forEach { it.deleteRecursively() }
        }
    }
}
