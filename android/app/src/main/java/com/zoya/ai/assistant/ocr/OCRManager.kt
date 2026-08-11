package com.zoya.ai.assistant.ocr

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.zoya.ai.assistant.bridge.BridgeResult
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume

/**
 * On-device OCR (ML Kit Text Recognition v2). Only invoked on-demand — never runs continuously —
 * and results are cached briefly by the caller (AutomationEngine / workflow layer) as the PRD
 * requires, rather than inside this stateless manager.
 */
class OCRManager {

    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

    suspend fun recognize(bitmap: Bitmap): BridgeResult = suspendCancellableCoroutine { cont ->
        val image = InputImage.fromBitmap(bitmap, 0)
        recognizer.process(image)
            .addOnSuccessListener { visionText ->
                val blocks = JSONArray()
                for (block in visionText.textBlocks) {
                    for (line in block.lines) {
                        val box = line.boundingBox
                        blocks.put(JSONObject().apply {
                            put("text", line.text)
                            put("bounds", JSONObject().apply {
                                put("left", box?.left ?: 0)
                                put("top", box?.top ?: 0)
                                put("right", box?.right ?: 0)
                                put("bottom", box?.bottom ?: 0)
                            })
                        })
                    }
                }
                if (cont.isActive) {
                    cont.resume(
                        BridgeResult.success(
                            "OCR complete",
                            JSONObject().put("fullText", visionText.text).put("lines", blocks)
                        )
                    )
                }
            }
            .addOnFailureListener { e ->
                if (cont.isActive) cont.resume(BridgeResult.failure("OCR failed: ${e.message}"))
            }
    }

    /** Finds the first recognized text line matching [query] (case-insensitive contains). */
    suspend fun findText(bitmap: Bitmap, query: String): BridgeResult {
        val result = recognize(bitmap)
        if (result.status != com.zoya.ai.assistant.bridge.ResultStatus.SUCCESS) return result
        val lines = result.data?.optJSONArray("lines") ?: JSONArray()
        for (i in 0 until lines.length()) {
            val line = lines.getJSONObject(i)
            if (line.optString("text").contains(query, ignoreCase = true)) {
                return BridgeResult.success("Found text", line)
            }
        }
        return BridgeResult.failure("Text '$query' not found on screen")
    }

    fun close() = recognizer.close()
}
