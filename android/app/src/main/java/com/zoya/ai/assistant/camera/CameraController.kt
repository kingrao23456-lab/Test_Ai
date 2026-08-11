package com.zoya.ai.assistant.camera

import android.content.ContentValues
import android.content.Context
import android.provider.MediaStore
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.zoya.ai.assistant.bridge.BridgeResult
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Locale
import kotlin.coroutines.resume

/**
 * CameraX-based capture. Requires an explicit prior CAMERA permission grant and a bound
 * lifecycle owner (an activity the user can see) — the camera is never opened silently.
 */
class CameraController(private val context: Context) {

    private var imageCapture: ImageCapture? = null

    suspend fun bind(lifecycleOwner: LifecycleOwner, useFrontCamera: Boolean): BridgeResult =
        suspendCancellableCoroutine { cont ->
            val providerFuture = ProcessCameraProvider.getInstance(context)
            providerFuture.addListener({
                try {
                    val provider = providerFuture.get()
                    val capture = ImageCapture.Builder().build()
                    val selector = if (useFrontCamera) CameraSelector.DEFAULT_FRONT_CAMERA
                    else CameraSelector.DEFAULT_BACK_CAMERA
                    provider.unbindAll()
                    provider.bindToLifecycle(lifecycleOwner, selector, capture)
                    imageCapture = capture
                    if (cont.isActive) cont.resume(BridgeResult.success("Camera bound"))
                } catch (e: Exception) {
                    if (cont.isActive) cont.resume(BridgeResult.failure("Could not open camera: ${e.message}"))
                }
            }, ContextCompat.getMainExecutor(context))
        }

    suspend fun takePhoto(): BridgeResult = suspendCancellableCoroutine { cont ->
        val capture = imageCapture
        if (capture == null) {
            cont.resume(BridgeResult.failure("Camera is not bound/open"))
            return@suspendCancellableCoroutine
        }
        val name = "zoya_${SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(System.currentTimeMillis())}.jpg"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Pictures/Zoya")
        }
        val outputOptions = ImageCapture.OutputFileOptions.Builder(
            context.contentResolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
        ).build()

        capture.takePicture(
            outputOptions,
            ContextCompat.getMainExecutor(context),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    if (cont.isActive) {
                        cont.resume(
                            BridgeResult.success(
                                "Photo saved",
                                JSONObject().put("uri", output.savedUri?.toString())
                            )
                        )
                    }
                }
                override fun onError(exception: ImageCaptureException) {
                    if (cont.isActive) cont.resume(BridgeResult.failure("Capture failed: ${exception.message}"))
                }
            }
        )
    }
}
