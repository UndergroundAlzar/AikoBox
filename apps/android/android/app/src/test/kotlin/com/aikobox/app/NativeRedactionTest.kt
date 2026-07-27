package com.aikobox.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeRedactionTest {
    @Test
    fun redactsUrlsAndNamedSecrets() {
        val result =
            NativeRedaction.message(
                "failed https://user:pass@example.com/config?token=abc password=hunter2 " +
                    "550e8400-e29b-41d4-a716-446655440000",
            )

        assertFalse(result.contains("user:pass"))
        assertFalse(result.contains("token=abc"))
        assertFalse(result.contains("hunter2"))
        assertFalse(result.contains("550e8400"))
        assertTrue(result.contains("[REDACTED-URL]"))
        assertTrue(result.contains("password=[REDACTED]"))
    }

    @Test
    fun limitsNativeMessages() {
        val result = NativeRedaction.message("x".repeat(1000))

        assertTrue(result.length <= 240)
    }
}
