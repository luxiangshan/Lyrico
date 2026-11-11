package com.lonx.lyrico.remote.webdav

import org.w3c.dom.Element
import org.w3c.dom.Node
import org.xml.sax.InputSource
import java.io.InputStream
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.time.OffsetDateTime
import java.util.Locale
import java.util.TimeZone
import javax.xml.parsers.DocumentBuilderFactory

/** One <D:response> of a PROPFIND multistatus. [hrefPath] is the decoded URL path (no scheme/host). */
internal data class DavResource(
    val hrefPath: String,
    val isCollection: Boolean,
    val contentLength: Long,
    val lastModifiedMillis: Long,
)

internal object WebDavXml {

    const val PROPFIND_BODY = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/></d:prop></d:propfind>"""

    /**
     * Parses a multistatus document. Namespace-aware with a fallback on local names, so documents using any
     * prefix (D:, d:, lp1:, default namespace) or sloppy servers that omit the DAV: namespace both work.
     */
    fun parseMultistatus(input: InputStream): List<DavResource> {
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            isExpandEntityReferences = false
            try { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) } catch (_: Exception) {}
            try { setFeature("http://xml.org/sax/features/external-general-entities", false) } catch (_: Exception) {}
        }
        val doc = factory.newDocumentBuilder().parse(InputSource(input))
        val root = doc.documentElement ?: return emptyList()
        return children(root, "response").mapNotNull { parseResponse(it) }
    }

    private fun parseResponse(resp: Element): DavResource? {
        val hrefRaw = child(resp, "href")?.textContent?.trim() ?: return null
        var isCollection = false
        var length = -1L
        var modified = 0L
        var contentType: String? = null
        for (propstat in children(resp, "propstat")) {
            val status = child(propstat, "status")?.textContent
            if (status != null && !status.contains(" 200")) continue
            val prop = child(propstat, "prop") ?: continue
            child(prop, "resourcetype")?.let { rt -> if (child(rt, "collection") != null) isCollection = true }
            child(prop, "getcontentlength")?.textContent?.trim()?.toLongOrNull()?.let { length = it }
            child(prop, "getlastmodified")?.textContent?.trim()?.let { modified = parseHttpDate(it) }
            child(prop, "getcontenttype")?.textContent?.trim()?.let { contentType = it }
        }
        if (contentType.equals("httpd/unix-directory", true)) isCollection = true
        return DavResource(hrefToPath(hrefRaw), isCollection, if (isCollection) -1 else length, modified)
    }

    /** Absolute or relative href -> decoded path, no trailing slash (except root). */
    fun hrefToPath(href: String): String {
        var h = href
        val scheme = h.indexOf("://")
        if (scheme in 1..10) {
            val slash = h.indexOf('/', scheme + 3)
            h = if (slash < 0) "/" else h.substring(slash)
        }
        h = h.substringBefore('?').substringBefore('#')
        return RemotePaths.normalize(RemotePaths.percentDecode(h))
    }

    private fun isNamed(n: Node, local: String): Boolean {
        if (n.nodeType != Node.ELEMENT_NODE) return false
        val ln = n.localName ?: n.nodeName.substringAfter(':')
        return ln.equals(local, ignoreCase = true)
    }

    private fun children(e: Element, local: String): List<Element> {
        val out = ArrayList<Element>()
        val nl = e.childNodes
        for (i in 0 until nl.length) {
            val n = nl.item(i)
            if (isNamed(n, local)) out.add(n as Element)
        }
        return out
    }

    private fun child(e: Element, local: String): Element? = children(e, local).firstOrNull()

    private val HTTP_DATE_PATTERNS = arrayOf(
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    )

    /** RFC 1123 (standard), RFC 850, asctime, or ISO-8601 (some servers). 0 when unparseable. */
    fun parseHttpDate(s: String): Long {
        for (p in HTTP_DATE_PATTERNS) {
            val f = SimpleDateFormat(p, Locale.US).apply { timeZone = TimeZone.getTimeZone("GMT"); isLenient = false }
            val pos = ParsePosition(0)
            val d = f.parse(s, pos)
            if (d != null && pos.index > 0) return d.time
        }
        return try { OffsetDateTime.parse(s).toInstant().toEpochMilli() } catch (_: Exception) { 0L }
    }
}
