package com.lonx.lyrico.remote.cloud115

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.SecureRandom
import java.util.Base64

/**
 * 115 "m115" payload cipher used by the proapi download-url endpoints.
 *
 * Port of SheltonZhu/115driver pkg/crypto/m115 (public.go, rsa.go, xor.go). The request body is
 * `data=<Encode(json, key)>`; the response `data` field is decoded with [decode] and the same key.
 * Note the RSA "decrypt" uses the public exponent: the server signs with its private key.
 */
object M115 {
    const val KEY_SIZE = 16

    private val N = BigInteger(
        "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021" +
            "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633" +
            "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1" +
            "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683",
        16,
    )
    private val E = BigInteger.valueOf(0x10001)
    private val KEY_LENGTH = N.bitLength() / 8 // 128

    private val XOR_KEY_SEED = intArrayOf(
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4, 0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86, 0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e, 0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59, 0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77, 0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
    )

    private val XOR_CLIENT_KEY = byteArrayOf(
        0x78, 0x06, 0xad.toByte(), 0x4c, 0x33, 0x86.toByte(), 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46,
    )

    private val random = SecureRandom()

    fun generateKey(): ByteArray = ByteArray(KEY_SIZE).also { random.nextBytes(it) }

    /** Encodes [input] with client [key] (16 bytes). [padSource] fills RSA padding bytes (tests inject it). */
    fun encode(input: ByteArray, key: ByteArray, padSource: (ByteArray) -> Unit = { random.nextBytes(it) }): String {
        require(key.size == KEY_SIZE)
        val buf = ByteArray(KEY_SIZE + input.size)
        key.copyInto(buf)
        input.copyInto(buf, KEY_SIZE)
        val body = buf.copyOfRange(KEY_SIZE, buf.size)
        xorTransform(body, xorDeriveKey(key, 4))
        body.reverse()
        xorTransform(body, XOR_CLIENT_KEY)
        body.copyInto(buf, KEY_SIZE)
        return Base64.getEncoder().encodeToString(rsaEncrypt(buf, padSource))
    }

    /** Decodes a server response [input] (base64) using the client [key] that encoded the request. */
    fun decode(input: String, key: ByteArray): ByteArray {
        val data = rsaDecrypt(Base64.getDecoder().decode(input.trim()))
        return decodeXor(data, key)
    }

    /** XOR stage of [decode], after RSA: first 16 bytes are the server key. */
    internal fun decodeXor(data: ByteArray, key: ByteArray): ByteArray {
        require(data.size >= KEY_SIZE) { "m115 payload too short" }
        val out = data.copyOfRange(KEY_SIZE, data.size)
        xorTransform(out, xorDeriveKey(data.copyOfRange(0, KEY_SIZE), 12))
        out.reverse()
        xorTransform(out, xorDeriveKey(key, 4))
        return out
    }

    internal fun xorDeriveKey(seed: ByteArray, size: Int): ByteArray {
        val key = ByteArray(size)
        for (i in 0 until size) {
            var v = ((seed[i].toInt() and 0xff) + XOR_KEY_SEED[size * i]) and 0xff
            v = v xor XOR_KEY_SEED[size * (size - i - 1)]
            key[i] = v.toByte()
        }
        return key
    }

    internal fun xorTransform(data: ByteArray, key: ByteArray) {
        val mod = data.size % 4
        for (i in 0 until mod) data[i] = (data[i].toInt() xor key[i % key.size].toInt()).toByte()
        for (i in mod until data.size) data[i] = (data[i].toInt() xor key[(i - mod) % key.size].toInt()).toByte()
    }

    private fun rsaEncrypt(input: ByteArray, padSource: (ByteArray) -> Unit): ByteArray {
        val out = ByteArrayOutputStream()
        var pos = 0
        while (pos < input.size) {
            val slice = minOf(KEY_LENGTH - 11, input.size - pos)
            val chunk = input.copyOfRange(pos, pos + slice)
            val padSize = KEY_LENGTH - chunk.size - 3
            val pad = ByteArray(padSize).also(padSource)
            val msg = ByteArray(KEY_LENGTH)
            msg[0] = 0; msg[1] = 2
            for (i in 0 until padSize) msg[2 + i] = ((pad[i].toInt() and 0xff) % 0xff + 1).toByte()
            msg[padSize + 2] = 0
            chunk.copyInto(msg, padSize + 3)
            out.write(toFixed(BigInteger(1, msg).modPow(E, N), KEY_LENGTH))
            pos += slice
        }
        return out.toByteArray()
    }

    private fun rsaDecrypt(input: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        var pos = 0
        while (pos < input.size) {
            val slice = minOf(KEY_LENGTH, input.size - pos)
            val ret = unsigned(BigInteger(1, input.copyOfRange(pos, pos + slice)).modPow(E, N))
            // Strip PKCS#1 v1.5 type-1/2 padding: plaintext starts after first zero byte (index > 0)
            for (i in 1 until ret.size) {
                if (ret[i].toInt() == 0) {
                    out.write(ret, i + 1, ret.size - i - 1)
                    break
                }
            }
            pos += slice
        }
        return out.toByteArray()
    }

    private fun unsigned(v: BigInteger): ByteArray {
        val b = v.toByteArray()
        return if (b.size > 1 && b[0].toInt() == 0) b.copyOfRange(1, b.size) else b
    }

    private fun toFixed(v: BigInteger, len: Int): ByteArray {
        val b = unsigned(v)
        if (b.size == len) return b
        val out = ByteArray(len)
        b.copyInto(out, len - b.size)
        return out
    }
}
