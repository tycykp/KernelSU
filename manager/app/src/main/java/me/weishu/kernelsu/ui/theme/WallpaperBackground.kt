package me.weishu.kernelsu.ui.theme

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import me.weishu.kernelsu.ui.util.WallpaperUtils

/**
 * Draws the custom wallpaper as the app-wide background, with an optional blur
 * radius and a dim scrim on top to keep the content readable.
 */
@Composable
fun WallpaperBackground(
    path: String,
    blur: Float,
    dim: Float,
    isDark: Boolean,
    modifier: Modifier = Modifier,
) {
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val targetWidth = with(density) { configuration.screenWidthDp.dp.toPx() }.toInt().coerceAtLeast(1)
    val targetHeight = with(density) { configuration.screenHeightDp.dp.toPx() }.toInt().coerceAtLeast(1)
    val bitmap by produceState<android.graphics.Bitmap?>(
        initialValue = null,
        path,
        targetWidth,
        targetHeight,
    ) {
        value = withContext(Dispatchers.Default) {
            WallpaperUtils.decodeSampledBitmap(path, targetWidth, targetHeight)
        }
    }

    val decoded = bitmap
    if (decoded != null) {
        Box(modifier = modifier.fillMaxSize()) {
            Image(
                bitmap = decoded.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier
                    .fillMaxSize()
                    .blur(blur.dp),
                contentScale = ContentScale.Crop,
            )
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        if (isDark) Color.Black.copy(alpha = dim.coerceIn(0f, 1f))
                        else Color.White.copy(alpha = dim.coerceIn(0f, 1f))
                    )
            )
        }
    }
}

@Composable
fun rememberWallpaperPreview(path: String, maxSize: Int = 512): androidx.compose.ui.graphics.ImageBitmap? {
    return remember(path, maxSize) {
        WallpaperUtils.decodeSampledBitmap(path, maxSize, maxSize)?.asImageBitmap()
    }
}
