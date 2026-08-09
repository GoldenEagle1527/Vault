package com.vault.vault.offload

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/**
 * Minimal AccessibilityService stub for Wave4 `vault-a11y` status/smoke.
 *
 * Does not perform UI automation (tap/swipe). Exists so the user can enable
 * the service in system Settings; [A11yHandler] reports whether our component
 * appears in [android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES].
 */
class VaultAccessibilityService : AccessibilityService() {
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Wave4 MVP: status/smoke only — no event handling.
    }

    override fun onInterrupt() {
        // no-op
    }
}
