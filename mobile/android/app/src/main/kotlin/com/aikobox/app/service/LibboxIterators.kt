package com.aikobox.app.service

import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.RoutePrefixIterator
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

/**
 * gomobile cannot express `[]string`, so every list crossing the JNI boundary is a
 * single-pass iterator. These are the Kotlin-side adapters.
 *
 * Two rules apply to everything here:
 *
 * 1. **Single pass.** Go drains an iterator exactly once. Handing the same instance to two
 *    calls yields an empty list on the second.
 * 2. **Materialise before you branch.** An iterator arriving *from* Go is backed by a Go
 *    slice whose reference is released when the call returns; the `toList` helpers below
 *    copy eagerly so the caller can look at the data twice — which `openTun` genuinely
 *    needs, because "are there any IPv4 addresses?" and "what are they?" are two questions
 *    about the same iterator.
 */

/** Wraps a Kotlin list as the `StringIterator` libbox expects. */
class LibboxStringArray(values: List<String>) : StringIterator {

    private val values = values.toList()
    private var cursor = 0

    override fun hasNext(): Boolean = cursor < values.size

    override fun next(): String = values[cursor++]

    override fun len(): Int = values.size
}

/** Wraps a Kotlin list as the `NetworkInterfaceIterator` libbox expects. */
class LibboxInterfaceArray(values: List<LibboxNetworkInterface>) : NetworkInterfaceIterator {

    private val values = values.toList()
    private var cursor = 0

    override fun hasNext(): Boolean = cursor < values.size

    override fun next(): LibboxNetworkInterface = values[cursor++]
}

/** Drains a Go-supplied string iterator into a Kotlin list. Null-tolerant. */
fun StringIterator?.toList(): List<String> {
    if (this == null) return emptyList()
    val out = ArrayList<String>()
    while (hasNext()) {
        out.add(next())
    }
    return out
}

/** One CIDR from a Go-supplied route iterator, flattened out of the proxy object. */
data class Prefix(val address: String, val prefixLength: Int)

/** Drains a Go-supplied route iterator into plain Kotlin data. Null-tolerant. */
fun RoutePrefixIterator?.toPrefixList(): List<Prefix> {
    if (this == null) return emptyList()
    val out = ArrayList<Prefix>()
    while (hasNext()) {
        val prefix: RoutePrefix = next()
        out.add(Prefix(prefix.address(), prefix.prefix()))
    }
    return out
}
