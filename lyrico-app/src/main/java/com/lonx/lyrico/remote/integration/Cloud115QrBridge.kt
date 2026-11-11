package com.lonx.lyrico.remote.integration

import com.lonx.lyrico.remote.cloud115.Cloud115QrLogin

/** UI-facing state of a 115 QR login. */
enum class QrLoginState { WAITING, SCANNED, CONFIRMED, EXPIRED, CANCELLED }

/**
 * Thin adapter over [Cloud115QrLogin] so the UI layer does not depend on provider internals.
 * All methods block; call them on Dispatchers.IO.
 */
interface Cloud115QrBridge {
    /** Starts a new login and returns the text to encode as a QR code. */
    fun start(): String

    /** One (possibly long-polling) status check of the current login. */
    fun poll(): QrLoginState

    /** Exchanges a confirmed login for the 115 cookie string. */
    fun finish(): String
}

class Cloud115QrBridgeImpl(
    private val login: Cloud115QrLogin = Cloud115QrLogin(),
) : Cloud115QrBridge {
    @Volatile
    private var session: Cloud115QrLogin.Session? = null

    override fun start(): String {
        val created = login.start()
        session = created
        return created.qrContent
    }

    override fun poll(): QrLoginState {
        val current = session ?: return QrLoginState.EXPIRED
        return when (login.poll(current)) {
            Cloud115QrLogin.Status.WAITING -> QrLoginState.WAITING
            Cloud115QrLogin.Status.SCANNED -> QrLoginState.SCANNED
            Cloud115QrLogin.Status.CONFIRMED -> QrLoginState.CONFIRMED
            Cloud115QrLogin.Status.EXPIRED -> QrLoginState.EXPIRED
            Cloud115QrLogin.Status.CANCELLED -> QrLoginState.CANCELLED
        }
    }

    override fun finish(): String {
        val current = session ?: throw IllegalStateException("No QR login in progress")
        return login.login(current)
    }
}
