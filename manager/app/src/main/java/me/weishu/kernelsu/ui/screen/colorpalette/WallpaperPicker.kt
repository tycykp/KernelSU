package me.weishu.kernelsu.ui.screen.colorpalette

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import me.weishu.kernelsu.ui.util.WallpaperUtils

/**
 * Creates a launcher that opens the system photo picker, copies the picked image
 * into app-private storage, replaces the previous wallpaper file and reports the
 * new path through [onSetWallpaperPath].
 */
@Composable
fun rememberWallpaperPicker(
    currentPath: String?,
    onSetWallpaperPath: (String?) -> Unit,
): () -> Unit {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri != null) {
            scope.launch {
                val newPath = withContext(Dispatchers.IO) {
                    val saved = WallpaperUtils.saveWallpaper(context, uri)
                    if (saved != null) {
                        WallpaperUtils.deleteWallpaper(context, currentPath)
                    }
                    saved
                }
                if (newPath != null) {
                    onSetWallpaperPath(newPath)
                }
            }
        }
    }
    return {
        launcher.launch(
            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
        )
    }
}
