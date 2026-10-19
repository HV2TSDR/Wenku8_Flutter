package org.mewx.wenku8_flutter

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.FileProvider
import java.io.File
import java.util.UUID

internal data class VerifiedUpdate(val file: File, val version: String, val build: Long) {
    fun metadata(): Map<String, Any> = mapOf("version" to version, "build" to build)
}

/** Each handed-off URI names one immutable APK, never the next download. */
internal class UpdatePackages(private val context: Context) {
    private val root get() = File(context.cacheDir, "updates").canonicalFile
    private val flags get() = if (Build.VERSION.SDK_INT >= 28) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else {
        @Suppress("DEPRECATION")
        PackageManager.GET_SIGNATURES
    }

    @Suppress("DEPRECATION")
    fun installed(): PackageInfo = context.packageManager.getPackageInfo(context.packageName, flags)

    @Suppress("DEPRECATION")
    fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) {
        info.longVersionCode
    } else {
        info.versionCode.toLong()
    }

    @Suppress("DEPRECATION")
    fun inspect(path: String, version: String, expectedBuild: Long? = null): VerifiedUpdate {
        val apk = File(path).canonicalFile
        val parent = apk.parentFile
        val privateAttempt = parent?.parentFile == root && parent.name.startsWith("package-")
        // Keep the existing native entry point usable for older callers. The
        // legacy mutable file is snapshotted by forInstall before sharing it.
        require((parent == root || privateAttempt) && apk.name == "update.apk" && apk.isFile) {
            "安装包路径无效，请重新下载"
        }
        val archive = context.packageManager.getPackageArchiveInfo(apk.path, flags)
            ?: throw IllegalArgumentException("安装包不完整，请重新下载")
        val current = installed()
        require(archive.packageName == context.packageName) { "安装包不属于本应用，请重新下载" }
        val build = code(archive)
        require(archive.versionName == version && (expectedBuild == null || build == expectedBuild)) {
            "安装包为 ${archive.versionName}（$build），与所选更新不符，请重新下载"
        }
        require(build > code(current)) {
            "安装包为 ${archive.versionName}（$build），本机已安装 ${current.versionName}（${code(current)}），请重新检查更新"
        }
        val signed = if (Build.VERSION.SDK_INT >= 28) {
            val old = current.signingInfo ?: throw IllegalArgumentException("无法读取当前签名")
            val next = archive.signingInfo ?: throw IllegalArgumentException("安装包缺少有效签名")
            if (old.hasMultipleSigners() || next.hasMultipleSigners()) {
                old.apkContentsSigners.toSet() == next.apkContentsSigners.toSet()
            } else {
                next.signingCertificateHistory.orEmpty().contains(old.apkContentsSigners.singleOrNull())
            }
        } else {
            current.signatures.orEmpty().toSet() == archive.signatures.orEmpty().toSet() &&
                !archive.signatures.isNullOrEmpty()
        }
        require(signed) { "安装包签名与当前版本不一致，无法覆盖升级，请重新下载" }
        return VerifiedUpdate(apk, version, build)
    }

    fun forInstall(path: String, version: String, expectedBuild: Long? = null): VerifiedUpdate {
        val verified = inspect(path, version, expectedBuild)
        if (verified.file.parentFile != root) return verified
        val snapshot = File(root, "package-${UUID.randomUUID()}")
        check(snapshot.mkdir()) { "无法准备安装包，请重新下载" }
        try {
            val file = verified.file.copyTo(File(snapshot, "update.apk"))
            return inspect(file.path, version, expectedBuild)
        } catch (failure: Exception) {
            snapshot.deleteRecursively()
            throw failure
        }
    }

    fun installIntent(update: VerifiedUpdate): Intent {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", update.file)
        return Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            clipData = ClipData.newRawUri("APK", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }
}
