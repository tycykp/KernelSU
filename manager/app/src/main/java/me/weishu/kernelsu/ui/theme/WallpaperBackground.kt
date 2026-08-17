package me.weishu.kernelsu.ui.theme

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.BiasAlignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.ScaleFactor
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import me.weishu.kernelsu.ui.util.WallpaperUtils

/**
 * Draws the custom wallpaper as the app-wide background. Cropping is
 * non-destructive: [cropScale] zooms the image after the initial crop, while
 * [positionX] and [positionY] choose which part remains visible.
 */
@Composable
fun WallpaperBackground(
    path: String,
    blur: Float,
    dim: Float,
    opacity: Float,
    cropScale: Float,
    positionX: Float,
    positionY: Float,
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

    bitmap?.let {
        WallpaperImage(
            bitmap = it.asImageBitmap(),
            blur = blur,
            dim = dim,
            opacity = opacity,
            cropScale = cropScale,
            positionX = positionX,
            positionY = positionY,
            isDark = isDark,
            modifier = modifier,
        )
    }
}

@Composable
fun WallpaperImage(
    bitmap: ImageBitmap,
    blur: Float,
    dim: Float,
    opacity: Float,
    cropScale: Float,
    positionX: Float,
    positionY: Float,
    isDark: Boolean,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(if (isDark) Color.Black else Color.White)
    ) {
        Image(
            bitmap = bitmap,
            contentDescription = null,
            modifier = Modifier
                .fillMaxSize()
                .blur(blur.coerceAtLeast(0f).dp)
                .alpha(opacity.coerceIn(0f, 1f)),
            alignment = wallpaperAlignment(positionX, positionY),
            contentScale = wallpaperContentScale(cropScale),
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

@Composable
fun rememberWallpaperPreview(path: String, maxSize: Int = 512): ImageBitmap? {
    return remember(path, maxSize) {
        WallpaperUtils.decodeSampledBitmap(path, maxSize, maxSize)?.asImageBitmap()
    }
}

fun wallpaperAlignment(positionX: Float, positionY: Float): BiasAlignment = BiasAlignment(
    horizontalBias = positionX.coerceIn(-1f, 1f),
    verticalBias = positionY.coerceIn(-1f, 1f),
)

fun wallpaperContentScale(cropScale: Float): ContentScale {
    val scale = cropScale.coerceIn(1f, 3f)
    return object : ContentScale {
        override fun computeScaleFactor(srcSize: Size, dstSize: Size): ScaleFactor {
            val crop = ContentScale.Crop.computeScaleFactor(srcSize, dstSize)
            return ScaleFactor(crop.scaleX * scale, crop.scaleY * scale)
        }
    }
}
