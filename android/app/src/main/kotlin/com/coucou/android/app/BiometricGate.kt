package com.coucou.android.app

import android.app.Activity
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal

/**
 * "Allow" from the phone needs the user's face, fingerprint or screen lock, like Face ID on the
 * iPhone. With no screen lock set up, Allow is refused: Deny always works.
 */
object BiometricGate {
    private const val AUTH = BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL

    fun available(activity: Activity): Boolean =
        activity.getSystemService(BiometricManager::class.java).canAuthenticate(AUTH) == BiometricManager.BIOMETRIC_SUCCESS

    fun confirm(activity: Activity, title: String, subtitle: String, noLockMessage: String, onSuccess: () -> Unit, onFail: (String) -> Unit) {
        if (!available(activity)) { onFail(noLockMessage); return }
        BiometricPrompt.Builder(activity)
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(AUTH)
            .build()
            .authenticate(
                CancellationSignal(), activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onSuccess()
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        val cancelled = errorCode == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED ||
                            errorCode == BiometricPrompt.BIOMETRIC_ERROR_CANCELED
                        onFail(if (cancelled) "" else errString.toString()) // empty: the user backed out, say nothing
                    }
                },
            )
    }
}
