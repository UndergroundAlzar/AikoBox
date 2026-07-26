package com.aikobox.app.service

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.ProxyInfo
import android.net.Uri
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Process
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.KeyStore
import java.security.cert.Certificate
import java.util.Collections
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface
import io.nekohasekai.libbox.Notification as LibboxNotification
import java.net.NetworkInterface as JavaNetworkInterface

/**
 * The Android side of libbox's `PlatformInterface`.
 *
 * The Go core cannot see Android at all: it cannot open a tun, protect a socket, enumerate
 * interfaces, attribute a connection to a UID, or read the trust store. Every one of those
 * is a callback into this class, invoked from a Go-owned thread.
 *
 * Three properties of the contract are worth stating because getting them wrong produces
 * bugs that only show up on a device:
 *
 * * **The tun fd is shared, not transferred.** Go calls `dup()` on the integer returned from
 *   [openTun] and owns the duplicate; this side keeps the original `ParcelFileDescriptor` and
 *   must hold a strong reference to it for the tunnel's lifetime. Returning `detachFd()` or
 *   letting the object be collected kills the tunnel non-deterministically.
 * * **Allow-list and deny-list are mutually exclusive.** `VpnService.Builder` throws
 *   `UnsupportedOperationException` if both are used, and a single uninstalled package throws
 *   `NameNotFoundException` — so each entry is caught individually. A stale profile naming an
 *   app the user has since removed must not take the whole tunnel down.
 * * **Callbacks run on Go threads.** Nothing here may touch the main looper synchronously or
 *   block on it.
 */
class AikoPlatformInterface(private val service: AikoVpnService) : PlatformInterface {

    private val appContext get() = service.applicationContext

    private val connectivity: ConnectivityManager?
        get() = appContext.getSystemService(ConnectivityManager::class.java)

    @Volatile
    private var monitorCallback: ConnectivityManager.NetworkCallback? = null

    // -----------------------------------------------------------------------
    // Capabilities
    // -----------------------------------------------------------------------

    /**
     * No platform DNS transport.
     *
     * Returning null makes the core resolve through the servers its own configuration
     * declares, which is what the converter emits and what the desktop app does. Handing
     * the system resolver back would route DNS outside the tunnel unless every caller
     * remembered to protect it — a leak waiting to happen.
     */
    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    /** Keeps the core's own outbound sockets off the tun so traffic cannot loop. */
    override fun autoDetectInterfaceControl(fd: Int) {
        if (!service.protect(fd)) {
            // Not fatal on its own — protect() fails when the VPN is already gone — but it
            // is exactly the failure that turns into a routing loop, so it is never silent.
            service.log(AikoCoreContract.LEVEL_WARNING, "protect($fd) failed")
        }
    }

    /**
     * `/proc/net` is readable up to Android 9; from Android 10 the kernel hides other UIDs'
     * sockets and [findConnectionOwner] is the only way to attribute a connection.
     */
    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    // -----------------------------------------------------------------------
    // Tun
    // -----------------------------------------------------------------------

    override fun openTun(options: TunOptions): Int {
        // Under always-on VPN there is no Activity and consent is implicit, so prepare()
        // returns null. Anywhere else a non-null result means we were revoked between the
        // consent check and here.
        if (VpnService.prepare(service) != null) {
            throw IllegalStateException("android: missing vpn permission")
        }

        val builder = service.newTunBuilder()
            .setSession(SESSION_NAME)
            .setMtu(options.getMTU())
        builder.setBlocking(false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // The tun is not itself a metered link; metering is a property of whatever
            // carries it, and claiming otherwise makes apps refuse to sync on Wi-Fi.
            builder.setMetered(false)
        }

        val inet4 = options.getInet4Address().toPrefixList()
        val inet6 = options.getInet6Address().toPrefixList()
        if (inet4.isEmpty() && inet6.isEmpty()) {
            throw IllegalStateException("android: tun configuration has no address")
        }
        for (prefix in inet4 + inet6) {
            builder.addAddress(prefix.address, prefix.prefixLength)
        }

        if (options.getAutoRoute()) {
            applyDnsServer(builder, options)
            applyRoutes(builder, options, hasInet4 = inet4.isNotEmpty(), hasInet6 = inet6.isNotEmpty())
            applyPackageFilter(builder, options)
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.getHTTPProxyServer(),
                    options.getHTTPProxyServerPort(),
                    options.getHTTPProxyBypassDomain().toList(),
                ),
            )
        }

        val descriptor = builder.establish()
            ?: throw IllegalStateException("android: the application is not prepared or is revoked")
        // Retain before returning: from this point Go owns a dup of the integer and this
        // object owns the only handle that can close the original.
        service.adoptTunDescriptor(descriptor)
        service.log(
            AikoCoreContract.LEVEL_INFO,
            "tun established, mtu=${options.getMTU()}, addresses=${(inet4 + inet6).joinToString { "${it.address}/${it.prefixLength}" }}",
        )
        return descriptor.fd
    }

    private fun applyDnsServer(builder: VpnService.Builder, options: TunOptions) {
        // getDNSServerAddress() throws rather than returning null when the config declares
        // no DNS server for the tun, which is a legitimate configuration.
        val address = runCatching { options.getDNSServerAddress()?.value }.getOrNull()
        if (address.isNullOrBlank()) return
        runCatching { builder.addDnsServer(address) }
            .onFailure { service.log(AikoCoreContract.LEVEL_WARNING, "tun dns $address rejected: ${it.message}") }
    }

    private fun applyRoutes(
        builder: VpnService.Builder,
        options: TunOptions,
        hasInet4: Boolean,
        hasInet6: Boolean,
    ) {
        val canExclude = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        val inet4Exclude = options.getInet4RouteExcludeAddress().toPrefixList()
        val inet6Exclude = options.getInet6RouteExcludeAddress().toPrefixList()
        val needsExclusions = inet4Exclude.isNotEmpty() || inet6Exclude.isNotEmpty()

        if (!canExclude && needsExclusions) {
            // Before Android 13 there is no excludeRoute(). The core pre-computes route
            // ranges with the exclusions already subtracted precisely for this case;
            // ignoring them would route excluded destinations into the tunnel anyway.
            addRoutes(builder, options.getInet4RouteRange().toPrefixList(), hasInet4, DEFAULT_ROUTE_V4)
            addRoutes(builder, options.getInet6RouteRange().toPrefixList(), hasInet6, DEFAULT_ROUTE_V6)
            return
        }

        addRoutes(builder, options.getInet4RouteAddress().toPrefixList(), hasInet4, DEFAULT_ROUTE_V4)
        addRoutes(builder, options.getInet6RouteAddress().toPrefixList(), hasInet6, DEFAULT_ROUTE_V6)

        if (!canExclude) return
        for (prefix in inet4Exclude + inet6Exclude) {
            runCatching {
                builder.excludeRoute(IpPrefix(InetAddress.getByName(prefix.address), prefix.prefixLength))
            }.onFailure {
                service.log(
                    AikoCoreContract.LEVEL_WARNING,
                    "excluded route ${prefix.address}/${prefix.prefixLength} rejected: ${it.message}",
                )
            }
        }
    }

    private fun addRoutes(
        builder: VpnService.Builder,
        prefixes: List<Prefix>,
        hasFamily: Boolean,
        defaultRoute: String,
    ) {
        if (prefixes.isEmpty()) {
            if (hasFamily) builder.addRoute(defaultRoute, 0)
            return
        }
        for (prefix in prefixes) {
            runCatching { builder.addRoute(prefix.address, prefix.prefixLength) }
                .onFailure {
                    service.log(
                        AikoCoreContract.LEVEL_WARNING,
                        "route ${prefix.address}/${prefix.prefixLength} rejected: ${it.message}",
                    )
                }
        }
    }

    private fun applyPackageFilter(builder: VpnService.Builder, options: TunOptions) {
        val include = options.getIncludePackage().toList()
        val exclude = options.getExcludePackage().toList()
        val self = service.packageName

        when {
            include.isNotEmpty() -> {
                // AikoBox routes itself, matching the desktop build where the tun is
                // system-wide. Announced rather than assumed: it is a visible change to
                // what the user asked for.
                val effective = (include + self).distinct()
                if (self !in include) {
                    service.log(AikoCoreContract.LEVEL_INFO, "split tunnel: adding $self to the allow-list")
                }
                for (name in effective) {
                    try {
                        builder.addAllowedApplication(name)
                    } catch (e: PackageManager.NameNotFoundException) {
                        service.log(AikoCoreContract.LEVEL_WARNING, "split tunnel: $name is not installed, skipped")
                    }
                }
            }

            exclude.isNotEmpty() -> {
                if (self in exclude) {
                    service.log(AikoCoreContract.LEVEL_INFO, "split tunnel: removing $self from the deny-list")
                }
                for (name in exclude.filterNot { it == self }.distinct()) {
                    try {
                        builder.addDisallowedApplication(name)
                    } catch (e: PackageManager.NameNotFoundException) {
                        service.log(AikoCoreContract.LEVEL_WARNING, "split tunnel: $name is not installed, skipped")
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Interface enumeration and monitoring
    // -----------------------------------------------------------------------

    override fun getInterfaces(): NetworkInterfaceIterator {
        val metadata = readNetworkMetadata()
        val interfaces = ArrayList<LibboxNetworkInterface>()
        val candidates = runCatching {
            Collections.list(JavaNetworkInterface.getNetworkInterfaces())
        }.getOrNull() ?: return LibboxInterfaceArray(interfaces)

        for (candidate in candidates) {
            val extra = metadata[candidate.name]
            interfaces.add(
                LibboxNetworkInterface().apply {
                    name = candidate.name
                    index = candidate.index
                    mtu = runCatching { candidate.mtu }.getOrDefault(0)
                    addresses = LibboxStringArray(
                        candidate.interfaceAddresses.mapNotNull { entry ->
                            val host = entry.address?.hostAddress ?: return@mapNotNull null
                            "$host/${entry.networkPrefixLength}"
                        },
                    )
                    flags = flagsOf(candidate)
                    type = extra?.type ?: Libbox.InterfaceTypeOther
                    metered = extra?.metered ?: false
                    dnsServer = LibboxStringArray(extra?.dnsServers ?: emptyList())
                },
            )
        }
        return LibboxInterfaceArray(interfaces)
    }

    private fun flagsOf(candidate: JavaNetworkInterface): Int {
        var flags = 0
        runCatching { if (candidate.isUp) flags = flags or OsConstants.IFF_UP }
        runCatching { if (candidate.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK }
        runCatching { if (candidate.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT }
        runCatching { if (candidate.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST }
        return flags
    }

    private class NetworkMetadata(
        val type: Int,
        val metered: Boolean,
        val dnsServers: List<String>,
    )

    @Suppress("DEPRECATION")
    private fun readNetworkMetadata(): Map<String, NetworkMetadata> {
        val manager = connectivity ?: return emptyMap()
        val out = HashMap<String, NetworkMetadata>()
        val networks = runCatching { manager.allNetworks }.getOrNull() ?: return out
        for (network in networks) {
            val link = runCatching { manager.getLinkProperties(network) }.getOrNull() ?: continue
            val name = link.interfaceName ?: continue
            val capabilities = runCatching { manager.getNetworkCapabilities(network) }.getOrNull()
            out[name] = NetworkMetadata(
                type = typeOf(capabilities),
                metered = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true,
                dnsServers = link.dnsServers.mapNotNull { it.hostAddress },
            )
        }
        return out
    }

    private fun typeOf(capabilities: NetworkCapabilities?): Int = when {
        capabilities == null -> Libbox.InterfaceTypeOther
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
        else -> Libbox.InterfaceTypeOther
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val manager = connectivity ?: throw IllegalStateException("android: no ConnectivityManager")
        closeDefaultInterfaceMonitor(listener)

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = publish(listener, network)

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) =
                publish(listener, network)

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) =
                publish(listener, network, linkProperties)

            override fun onLost(network: Network) {
                // An index of -1 with an empty name is how libbox spells "no default route".
                listener.updateDefaultInterface("", -1, false, false)
            }
        }

        manager.registerDefaultNetworkCallback(callback)
        monitorCallback = callback

        // Seed the core with the current default. Without this it waits for the first
        // network *change*, which on a stable connection never comes.
        val active = runCatching { manager.activeNetwork }.getOrNull()
        if (active != null) publish(listener, active)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val callback = monitorCallback ?: return
        monitorCallback = null
        runCatching { connectivity?.unregisterNetworkCallback(callback) }
    }

    private fun publish(
        listener: InterfaceUpdateListener,
        network: Network,
        linkProperties: LinkProperties? = null,
    ) {
        val manager = connectivity ?: return
        val link = linkProperties ?: runCatching { manager.getLinkProperties(network) }.getOrNull() ?: return
        val name = link.interfaceName ?: return
        val index = runCatching { JavaNetworkInterface.getByName(name)?.index ?: -1 }.getOrDefault(-1)
        val capabilities = runCatching { manager.getNetworkCapabilities(network) }.getOrNull()
        val expensive = capabilities == null ||
            !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        // `constrained` mirrors Apple's NWPath.isConstrained (Low Data Mode). Android's
        // nearest equivalent, NET_CAPABILITY_NOT_BANDWIDTH_CONSTRAINED, only exists from
        // API 35 and carries no meaning for the outbounds this app generates, so it is
        // reported as unconstrained rather than guessed at from the metered flag.
        listener.updateDefaultInterface(name, index, expensive, false)
    }

    // -----------------------------------------------------------------------
    // Connection attribution
    // -----------------------------------------------------------------------

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw UnsupportedOperationException("android: getConnectionOwnerUid requires API 29")
        }
        val manager = connectivity ?: throw IllegalStateException("android: no ConnectivityManager")
        val uid = manager.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(InetAddress.getByName(sourceAddress), sourcePort),
            InetSocketAddress(InetAddress.getByName(destinationAddress), destinationPort),
        )
        if (uid == Process.INVALID_UID) {
            throw NoSuchElementException("android: no owner for $sourceAddress:$sourcePort")
        }
        val packages = runCatching { appContext.packageManager.getPackagesForUid(uid) }.getOrNull()
        return ConnectionOwner().apply {
            userId = uid
            userName = runCatching { appContext.packageManager.getNameForUid(uid) }.getOrNull().orEmpty()
            setAndroidPackageNames(LibboxStringArray(packages?.filterNotNull() ?: emptyList()))
        }
    }

    // -----------------------------------------------------------------------
    // Wi-Fi, certificates, DNS cache
    // -----------------------------------------------------------------------

    /**
     * SSID/BSSID for `wifi_ssid` / `wifi_bssid` routing rules.
     *
     * On Android 10+ the SSID is only readable with a location permission, which this app
     * does not request. Returning null is the honest answer in that case; the alternative —
     * handing the core the literal string `<unknown ssid>` — would make a rule silently
     * match the wrong network.
     */
    override fun readWIFIState(): WIFIState? {
        val wifi = appContext.getSystemService(WifiManager::class.java) ?: return null
        @Suppress("DEPRECATION")
        val info = runCatching { wifi.connectionInfo }.getOrNull() ?: return null
        val raw = info.ssid ?: return null
        val ssid = raw.removeSurrounding("\"")
        if (ssid.isEmpty() || ssid == UNKNOWN_SSID) return null
        return Libbox.newWIFIState(ssid, info.bssid.orEmpty())
    }

    /**
     * The device trust store, PEM-encoded.
     *
     * Go cannot read `AndroidCAStore` itself, so without this every TLS handshake the core
     * makes against a host with a system-trusted certificate fails.
     */
    override fun systemCertificates(): StringIterator {
        val pem = ArrayList<String>()
        runCatching {
            val store = KeyStore.getInstance("AndroidCAStore")
            store.load(null, null)
            for (alias in Collections.list(store.aliases())) {
                val certificate: Certificate = store.getCertificate(alias) ?: continue
                pem.add(encodePem(certificate.encoded))
            }
        }.onFailure { Log.w(TAG, "cannot read AndroidCAStore", it) }
        return LibboxStringArray(pem)
    }

    private fun encodePem(der: ByteArray): String {
        val body = Base64.encodeToString(der, Base64.NO_WRAP)
        val wrapped = body.chunked(64).joinToString("\n")
        return "-----BEGIN CERTIFICATE-----\n$wrapped\n-----END CERTIFICATE-----\n"
    }

    /**
     * Android has no user-space DNS cache flush. Re-setting the underlying networks makes
     * the framework re-evaluate the VPN's link properties, which is the closest available
     * equivalent and is what sing-box-for-android does.
     */
    override fun clearDNSCache() {
        runCatching { service.setUnderlyingNetworks(null) }
    }

    // -----------------------------------------------------------------------
    // Notifications raised by the core itself
    // -----------------------------------------------------------------------

    override fun sendNotification(notification: LibboxNotification) {
        val manager = appContext.getSystemService(android.app.NotificationManager::class.java) ?: return
        AikoNotifications.ensureChannels(appContext)

        val builder = NotificationCompat.Builder(appContext, AikoNotifications.CHANNEL_NOTICES)
            .setSmallIcon(com.aikobox.app.R.drawable.ic_stat_tunnel)
            .setContentTitle(notification.title.ifEmpty { notification.typeName })
            .setContentText(notification.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(notification.body))
            .setAutoCancel(true)
        if (notification.subtitle.isNotEmpty()) {
            builder.setSubText(notification.subtitle)
        }
        val openUrl = notification.openURL
        if (openUrl.isNotEmpty()) {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(openUrl))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            builder.setContentIntent(
                PendingIntent.getActivity(
                    appContext,
                    openUrl.hashCode(),
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        }
        val id = notification.identifier.ifEmpty { notification.typeName }.hashCode()
        runCatching { manager.notify(id, builder.build()) }
    }

    private companion object {
        const val TAG = "AikoPlatformInterface"

        /** Shown in Settings → Network → VPN. Not localised: it is an identifier, not copy. */
        const val SESSION_NAME = "AikoBox"

        const val DEFAULT_ROUTE_V4 = "0.0.0.0"
        const val DEFAULT_ROUTE_V6 = "::"
        const val UNKNOWN_SSID = "<unknown ssid>"
    }
}
