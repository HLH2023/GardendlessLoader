package io.github.dey410.gardendlessloader.appupdate

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

/**
 * Opens the system package installer for an APK this app downloaded itself.
 *
 * The APK is handed over as a `content://` URI from [FileProvider], whose
 * authority is `<package>.fileprovider` and whose paths (`res/xml/file_paths.xml`)
 * expose only the app's own `downloads` folder. The installer therefore needs
 * no storage permission and no other app can read the file.
 *
 * The host repeats the checks the Dart side already made: the path must be a
 * regular `.apk` file inside the downloads folder. Android 8+ additionally
 * requires the user to allow this package to install unknown apps; when that
 * grant is missing the settings screen is opened and [InstallFailure] carries
 * [ERROR_PERMISSION_REQUIRED] so the UI can ask for a retry.
 */
class ApkInstaller(private val activity: Activity) {

    /** A refused install; [code] is what the Dart side maps to a message. */
    class InstallFailure(val code: String, message: String) : Exception(message)

    companion object {
        const val PROVIDER_SUFFIX = ".fileprovider"
        const val ERROR_PERMISSION_REQUIRED = "install_permission_required"
        const val ERROR_FILE_MISSING = "install_file_missing"
        const val ERROR_FILE_INVALID = "install_file_invalid"
        const val ERROR_NO_INSTALLER = "install_no_installer"
        const val ERROR_FAILED = "install_failed"

        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        private const val RESOURCE_FOLDER = "GardendlessLoader"
        private const val DOWNLOAD_FOLDER = "downloads"
    }

    /** Android 8+ gates APK installs per package; older releases do not. */
    fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            activity.packageManager.canRequestPackageInstalls()

    /**
     * Opens `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES` scoped to this
     * package. Returns false when the platform has no such screen.
     */
    fun openUnknownSourcesSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${activity.packageName}"),
        )
        return runCatching { activity.startActivity(intent) }.isSuccess
    }

    /** Starts the installer activity for [rawPath]. */
    fun install(rawPath: String) {
        val apk = resolveApk(rawPath)
        if (!canInstallPackages()) {
            // Send the user to the grant screen first; the caller reports
            // ERROR_PERMISSION_REQUIRED and the UI offers a retry.
            openUnknownSourcesSettings()
            throw InstallFailure(
                ERROR_PERMISSION_REQUIRED,
                "This package may not install unknown apps yet",
            )
        }
        val uri = try {
            FileProvider.getUriForFile(
                activity,
                activity.packageName + PROVIDER_SUFFIX,
                apk,
            )
        } catch (error: IllegalArgumentException) {
            throw InstallFailure(
                ERROR_FILE_INVALID,
                error.message ?: "APK is outside the download folder",
            )
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME_TYPE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            activity.startActivity(intent)
        } catch (error: ActivityNotFoundException) {
            throw InstallFailure(ERROR_NO_INSTALLER, error.message ?: "No installer")
        } catch (error: Exception) {
            throw InstallFailure(ERROR_FAILED, error.message ?: "Installer failed")
        }
    }

    private fun resolveApk(rawPath: String): File {
        if (rawPath.isBlank()) {
            throw InstallFailure(ERROR_FILE_MISSING, "No APK path was given")
        }
        val file = File(rawPath)
        if (!file.isFile) {
            throw InstallFailure(ERROR_FILE_MISSING, "APK does not exist")
        }
        val apk = try {
            file.canonicalFile
        } catch (error: Exception) {
            throw InstallFailure(ERROR_FILE_INVALID, error.message ?: "Bad APK path")
        }
        if (!apk.name.endsWith(".apk", ignoreCase = true)) {
            throw InstallFailure(ERROR_FILE_INVALID, "Not an APK file")
        }
        if (apk.length() <= 0L) {
            throw InstallFailure(ERROR_FILE_INVALID, "APK is empty")
        }
        if (!isInsideDownloads(apk)) {
            throw InstallFailure(ERROR_FILE_INVALID, "APK is outside the download folder")
        }
        return apk
    }

    /**
     * True when [apk] lives under one of the app's own `downloads` folders.
     * These are the only roots `res/xml/file_paths.xml` exposes, so a file
     * that fails here could not be served by [FileProvider] either.
     */
    private fun isInsideDownloads(apk: File): Boolean {
        val canonical = runCatching { apk.canonicalPath }.getOrNull() ?: return false
        return downloadRoots().any { root ->
            val rootPath = runCatching { root.canonicalPath }.getOrNull() ?: return@any false
            canonical == rootPath || canonical.startsWith(rootPath + File.separator)
        }
    }

    private fun downloadRoots(): List<File> {
        val roots = mutableListOf<File>()
        activity.getExternalFilesDir(null)?.let {
            roots.add(File(it, "$RESOURCE_FOLDER/$DOWNLOAD_FOLDER"))
        }
        // Flutter's getApplicationDocumentsDirectory: the app_flutter dir.
        roots.add(File(activity.getDir("flutter", Activity.MODE_PRIVATE), "$RESOURCE_FOLDER/$DOWNLOAD_FOLDER"))
        return roots
    }
}
