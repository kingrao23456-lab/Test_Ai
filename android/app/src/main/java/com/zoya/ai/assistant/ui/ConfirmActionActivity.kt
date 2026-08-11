package com.zoya.ai.assistant.ui

import android.app.Activity
import android.os.Bundle
import androidx.appcompat.app.AlertDialog

/**
 * Blocking, explicit confirmation required before financial transactions, purchases,
 * deletions, uninstalls, sending sensitive info, or changing critical security settings —
 * per the PRD's "Sensitive Action Protection" section. The workflow/bridge layer must call
 * this (and receive a positive result) before performing any such action; it must never
 * skip this step or infer consent.
 */
class ConfirmActionActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "Confirm action"
        val message = intent.getStringExtra(EXTRA_MESSAGE) ?: "Zoya wants to perform a sensitive action."

        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(message)
            .setCancelable(false)
            .setPositiveButton("Allow") { _, _ -> finishWithResult(true) }
            .setNegativeButton("Deny") { _, _ -> finishWithResult(false) }
            .setOnCancelListener { finishWithResult(false) }
            .show()
    }

    private fun finishWithResult(confirmed: Boolean) {
        val data = android.content.Intent().putExtra(EXTRA_RESULT, confirmed)
        setResult(if (confirmed) Activity.RESULT_OK else Activity.RESULT_CANCELED, data)
        finish()
    }

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_MESSAGE = "message"
        const val EXTRA_RESULT = "confirmed"
    }
}

