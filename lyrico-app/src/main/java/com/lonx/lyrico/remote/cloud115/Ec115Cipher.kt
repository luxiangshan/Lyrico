package com.lonx.lyrico.remote.cloud115

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.math.BigInteger
import java.security.SecureRandom
import java.util.Base64
import java.util.zip.CRC32
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * ECDH(P-224) + AES cipher for 115's `uplb.115.com/4.0/initupload.php`.
 *
 * Port of SheltonZhu/115driver pkg/crypto/ec115/cipher.go. P-224 arithmetic is done in pure Kotlin
 * (BigInteger) so no BouncyCastle is needed (Android's/JDK's providers don't reliably expose secp224r1).
 *  - shared secret = x(d * remotePub) (28 bytes); AES key = secret[0..16], IV = secret[12..28]
 *  - request: AES-128-CBC/PKCS7 (115driver's hand-rolled XOR+ECB loop is exactly CBC)
 *  - response: AES-128-CBC no padding, then `[u16le len][lz4 block]` chunks
 *  - query `k_ec` = [encodeToken]
 */
class Ec115Cipher internal constructor(
    internal val key: ByteArray,
    internal val iv: ByteArray,
    /** 30 bytes: 0x1d, 0x02|0x03 (y parity), x(28). */
    internal val pubKey: ByteArray,
) {
    fun encrypt(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/CBC/PKCS5Padding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
        return c.doFinal(plain)
    }

    fun decrypt(cipherText: ByteArray): ByteArray {
        val usable = cipherText.size - cipherText.size % 16
        if (usable <= 0) throw IOException("115 upload init: empty encrypted response")
        val c = Cipher.getInstance("AES/CBC/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
        val plain = c.doFinal(cipherText, 0, usable)
        val out = ByteArrayOutputStream()
        var pos = 0
        while (pos + 2 <= plain.size) {
            val len = (plain[pos].toInt() and 0xff) or ((plain[pos + 1].toInt() and 0xff) shl 8)
            if (len == 0 || pos + 2 + len > plain.size) break
            out.write(Lz4.decompressBlock(plain, pos + 2, len))
            pos += 2 + len
        }
        return out.toByteArray()
    }

    /** Builds the `k_ec` token. [r1]/[r2] are random mask bytes (tests pass 0). */
    fun encodeToken(timestamp: Long, r1: Int = rnd.nextInt(256), r2: Int = rnd.nextInt(256)): String {
        val t = timestamp.toInt() // uint32 truncation, little endian below (as 115driver)
        val tmp = ByteArrayOutputStream(48)
        for (i in 0 until 15) tmp.write(pubKey[i].toInt() xor r1)
        tmp.write(r1); tmp.write(0x73 xor r1)
        repeat(3) { tmp.write(r1) }
        for (i in 0 until 4) tmp.write(((t ushr (8 * i)) and 0xff) xor r1)
        for (i in 15 until pubKey.size) tmp.write(pubKey[i].toInt() xor r2)
        tmp.write(r2); tmp.write(0x01 xor r2)
        repeat(3) { tmp.write(r2) }
        val body = tmp.toByteArray()
        val crc = CRC32().apply { update(CRC_SALT); update(body) }.value
        for (i in 0 until 4) tmp.write(((crc ushr (8 * i)) and 0xff).toInt())
        return Base64.getEncoder().encodeToString(tmp.toByteArray())
    }

    companion object {
        private val rnd = SecureRandom()
        private val CRC_SALT = "^j>WD3Kr?J2gLFjD4W2y@".toByteArray(Charsets.US_ASCII)

        internal val REMOTE_PUB = byteArrayOf(
            0x57, 0xA2.toByte(), 0x92.toByte(), 0x57, 0xCD.toByte(), 0x23, 0x20, 0xE5.toByte(),
            0xD6.toByte(), 0xD1.toByte(), 0x43, 0x32, 0x2F, 0xA4.toByte(), 0xBB.toByte(), 0x8A.toByte(),
            0x3C, 0xF9.toByte(), 0xD3.toByte(), 0xCC.toByte(), 0x62, 0x3E, 0xF5.toByte(), 0xED.toByte(),
            0xAC.toByte(), 0x62, 0xB7.toByte(), 0x67, 0x8A.toByte(), 0x89.toByte(), 0xC9.toByte(), 0x1A,
            0x83.toByte(), 0xBA.toByte(), 0x80.toByte(), 0x0D, 0x61, 0x29, 0xF5.toByte(), 0x22,
            0xD0.toByte(), 0x34, 0xC8.toByte(), 0x95.toByte(), 0xDD.toByte(), 0x24, 0x65, 0x24,
            0x3A, 0xDD.toByte(), 0xC2.toByte(), 0x50, 0x95.toByte(), 0x3B, 0xEE.toByte(), 0xBA.toByte(),
        )

        /** Fresh ephemeral key pair, as 115driver's NewEcdhCipher. */
        fun create(): Ec115Cipher {
            var d: BigInteger
            do {
                d = BigInteger(P224.N.bitLength(), rnd)
            } while (d.signum() == 0 || d >= P224.N)
            return fromPrivate(d)
        }

        internal fun fromPrivate(d: BigInteger): Ec115Cipher {
            val pub = P224.mul(P224.G, d) ?: throw IllegalStateException("bad scalar")
            val remote = P224.Point(
                BigInteger(1, REMOTE_PUB.copyOfRange(0, 28)),
                BigInteger(1, REMOTE_PUB.copyOfRange(28, 56)),
            )
            val shared = P224.mul(remote, d) ?: throw IllegalStateException("bad shared point")
            val secret = P224.fixed(shared.x)
            val pubKey = ByteArray(30)
            pubKey[0] = 29
            pubKey[1] = if (pub.y.testBit(0)) 0x03 else 0x02
            P224.fixed(pub.x).copyInto(pubKey, 2)
            return Ec115Cipher(secret.copyOfRange(0, 16), secret.copyOfRange(12, 28), pubKey)
        }
    }
}

/** Minimal NIST P-224 (secp224r1) affine arithmetic for ECDH. */
internal object P224 {
    val P = BigInteger("ffffffffffffffffffffffffffffffff000000000000000000000001", 16)
    val A: BigInteger = P.subtract(BigInteger.valueOf(3))
    val B = BigInteger("b4050a850c04b3abf54132565044b0b7d7bfd8ba270b39432355ffb4", 16)
    val N = BigInteger("ffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3d", 16)
    val G = Point(
        BigInteger("b70e0cbd6bb4bf7f321390b94a03c1d356c21122343280d6115c1d21", 16),
        BigInteger("bd376388b5f723fb4c22dfe6cd4375a05a07476444d5819985007e34", 16),
    )

    data class Point(val x: BigInteger, val y: BigInteger)

    fun isOnCurve(p: Point): Boolean =
        p.y.multiply(p.y).mod(P) == p.x.pow(3).add(A.multiply(p.x)).add(B).mod(P)

    /** null = point at infinity. */
    fun add(p: Point?, q: Point?): Point? {
        if (p == null) return q
        if (q == null) return p
        val lambda = if (p.x == q.x) {
            if (p.y.add(q.y).mod(P).signum() == 0) return null
            p.x.multiply(p.x).multiply(BigInteger.valueOf(3)).add(A)
                .multiply(p.y.shiftLeft(1).modInverse(P)).mod(P)
        } else {
            q.y.subtract(p.y).multiply(q.x.subtract(p.x).mod(P).modInverse(P)).mod(P)
        }
        val x = lambda.multiply(lambda).subtract(p.x).subtract(q.x).mod(P)
        val y = lambda.multiply(p.x.subtract(x)).subtract(p.y).mod(P)
        return Point(x, y)
    }

    fun mul(p: Point, k: BigInteger): Point? {
        var r: Point? = null
        for (i in k.bitLength() - 1 downTo 0) {
            r = add(r, r)
            if (k.testBit(i)) r = add(r, p)
        }
        return r
    }

    fun fixed(v: BigInteger): ByteArray {
        val b = v.toByteArray()
        val out = ByteArray(28)
        if (b.size >= 28) b.copyInto(out, 0, b.size - 28, b.size) else b.copyInto(out, 28 - b.size)
        return out
    }
}

/** LZ4 block-format decompressor (no frame header), enough for 115's small JSON responses. */
internal object Lz4 {
    fun decompressBlock(src: ByteArray, offset: Int, length: Int): ByteArray {
        val out = ByteArrayOutputStream(maxOf(64, length * 4))
        var buf = ByteArray(0)
        var outLen = 0
        fun ensure(extra: Int) {
            if (outLen + extra > buf.size) buf = buf.copyOf(maxOf(buf.size * 2, outLen + extra, 256))
        }
        var i = offset
        val end = offset + length
        while (i < end) {
            val token = src[i++].toInt() and 0xff
            var litLen = token ushr 4
            if (litLen == 15) {
                while (true) {
                    if (i >= end) throw IOException("lz4: truncated literal length")
                    val b = src[i++].toInt() and 0xff
                    litLen += b
                    if (b != 255) break
                }
            }
            if (i + litLen > end) throw IOException("lz4: literal overrun")
            ensure(litLen)
            System.arraycopy(src, i, buf, outLen, litLen)
            outLen += litLen
            i += litLen
            if (i >= end) break // last sequence has literals only
            if (i + 2 > end) throw IOException("lz4: truncated offset")
            val off = (src[i].toInt() and 0xff) or ((src[i + 1].toInt() and 0xff) shl 8)
            i += 2
            if (off == 0 || off > outLen) throw IOException("lz4: bad offset")
            var matchLen = token and 0x0f
            if (matchLen == 15) {
                while (true) {
                    if (i >= end) throw IOException("lz4: truncated match length")
                    val b = src[i++].toInt() and 0xff
                    matchLen += b
                    if (b != 255) break
                }
            }
            matchLen += 4
            ensure(matchLen)
            var from = outLen - off
            repeat(matchLen) { buf[outLen++] = buf[from++] }
        }
        out.write(buf, 0, outLen)
        return out.toByteArray()
    }
}
