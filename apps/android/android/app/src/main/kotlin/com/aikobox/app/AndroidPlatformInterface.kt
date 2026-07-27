package com.aikobox.app

import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.ProxyInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterface
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface as JavaNetworkInterface
import java.security.KeyStore
import java.security.cert.X509Certificate

class AndroidPlatformInterface(
    private val service: AikoVpnService,
) : PlatformInterface, AutoCloseable {
    private val connectivityManager =
        service.getSystemService(ConnectivityManager::class.java)
    private val defaultNetworkMonitor = DefaultNetworkMonitor(service)

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        check(service.protect(fd)) { "Android VpnService.protect($fd) failed." }
    }

    override fun openTun(options: TunOptions): Int {
        check(android.net.VpnService.prepare(service) == null) {
            "VPN permission is missing or was revoked."
        }

        val builder =
            service.Builder()
                .setSession("AikoBox")
                .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        var hasIpv4 = false
        var hasIpv6 = false
        val ipv4Addresses = options.inet4Address
        while (ipv4Addresses.hasNext()) {
            val prefix = ipv4Addresses.next()
            builder.addAddress(prefix.address(), prefix.prefix())
            hasIpv4 = true
        }
        val ipv6Addresses = options.inet6Address
        while (ipv6Addresses.hasNext()) {
            val prefix = ipv6Addresses.next()
            builder.addAddress(prefix.address(), prefix.prefix())
            hasIpv6 = true
        }

        if (options.autoRoute) {
            runCatching { options.dnsServerAddress }
                .getOrNull()
                ?.value
                ?.takeIf(String::isNotBlank)
                ?.let(builder::addDnsServer)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                addRoutesApi33(builder, options, hasIpv4, hasIpv6)
            } else {
                addRouteRanges(builder, options)
            }
            addApplicationFilters(builder, options)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && options.isHTTPProxyEnabled) {
            val bypass = options.httpProxyBypassDomain.toStringList()
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    bypass,
                ),
            )
        }

        val descriptor =
            builder.establish()
                ?: error("Android rejected the VPN TUN interface establishment.")
        service.replaceTunDescriptor(descriptor)
        return descriptor.fd
    }

    private fun addRoutesApi33(
        builder: android.net.VpnService.Builder,
        options: TunOptions,
        hasIpv4: Boolean,
        hasIpv6: Boolean,
    ) {
        val ipv4Routes = options.inet4RouteAddress
        var hasIpv4Route = false
        while (ipv4Routes.hasNext()) {
            val prefix = ipv4Routes.next()
            builder.addRoute(
                android.net.IpPrefix(InetAddress.getByName(prefix.address()), prefix.prefix()),
            )
            hasIpv4Route = true
        }
        if (!hasIpv4Route && hasIpv4) builder.addRoute("0.0.0.0", 0)

        val ipv6Routes = options.inet6RouteAddress
        var hasIpv6Route = false
        while (ipv6Routes.hasNext()) {
            val prefix = ipv6Routes.next()
            builder.addRoute(
                android.net.IpPrefix(InetAddress.getByName(prefix.address()), prefix.prefix()),
            )
            hasIpv6Route = true
        }
        if (!hasIpv6Route && hasIpv6) builder.addRoute("::", 0)

        val ipv4Excludes = options.inet4RouteExcludeAddress
        while (ipv4Excludes.hasNext()) {
            val prefix = ipv4Excludes.next()
            builder.excludeRoute(
                android.net.IpPrefix(InetAddress.getByName(prefix.address()), prefix.prefix()),
            )
        }
        val ipv6Excludes = options.inet6RouteExcludeAddress
        while (ipv6Excludes.hasNext()) {
            val prefix = ipv6Excludes.next()
            builder.excludeRoute(
                android.net.IpPrefix(InetAddress.getByName(prefix.address()), prefix.prefix()),
            )
        }
    }

    private fun addRouteRanges(builder: android.net.VpnService.Builder, options: TunOptions) {
        val ipv4Routes = options.inet4RouteRange
        while (ipv4Routes.hasNext()) {
            val prefix = ipv4Routes.next()
            builder.addRoute(prefix.address(), prefix.prefix())
        }
        val ipv6Routes = options.inet6RouteRange
        while (ipv6Routes.hasNext()) {
            val prefix = ipv6Routes.next()
            builder.addRoute(prefix.address(), prefix.prefix())
        }
    }

    private fun addApplicationFilters(builder: android.net.VpnService.Builder, options: TunOptions) {
        val includes = options.includePackage
        while (includes.hasNext()) {
            val packageName = includes.next()
            try {
                builder.addAllowedApplication(packageName)
            } catch (_: PackageManager.NameNotFoundException) {
                Log.w(TAG, "Skipping unknown allowed application package")
            }
        }
        val excludes = options.excludePackage
        while (excludes.hasNext()) {
            val packageName = excludes.next()
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: PackageManager.NameNotFoundException) {
                Log.w(TAG, "Skipping unknown disallowed application package")
            }
        }
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            "Connection owner lookup uses libbox procfs below Android 10."
        }
        val uid =
            connectivityManager.getConnectionOwnerUid(
                ipProtocol,
                InetSocketAddress(sourceAddress, sourcePort),
                InetSocketAddress(destinationAddress, destinationPort),
            )
        check(uid != Process.INVALID_UID) { "Connection owner was not found." }
        val packages = service.packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        return ConnectionOwner().apply {
            userId = uid
            userName = packages.firstOrNull().orEmpty()
            setAndroidPackageNames(StringListIterator(packages))
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        defaultNetworkMonitor.start(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        defaultNetworkMonitor.stop(listener)
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val javaInterfaces =
            JavaNetworkInterface.getNetworkInterfaces()?.toList().orEmpty().associateBy { it.name }
        val result = mutableListOf<NetworkInterface>()

        for (network in connectivityManager.allNetworks) {
            val link = connectivityManager.getLinkProperties(network) ?: continue
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
            val name = link.interfaceName ?: continue
            val javaInterface = javaInterfaces[name] ?: continue
            result +=
                NetworkInterface().apply {
                    index = javaInterface.index
                    mtu = runCatching { javaInterface.mtu }.getOrDefault(0)
                    this.name = name
                    addresses =
                        StringListIterator(
                            javaInterface.interfaceAddresses.map { address ->
                                val host =
                                    if (address.address is Inet6Address) {
                                        Inet6Address.getByAddress(address.address.address).hostAddress
                                    } else {
                                        address.address.hostAddress
                                    }
                                "$host/${address.networkPrefixLength}"
                            },
                        )
                    flags = javaInterface.interfaceFlags()
                    type =
                        when {
                            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ->
                                Libbox.InterfaceTypeWIFI
                            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ->
                                Libbox.InterfaceTypeCellular
                            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ->
                                Libbox.InterfaceTypeEthernet
                            else -> Libbox.InterfaceTypeOther
                        }
                    dnsServer =
                        StringListIterator(link.dnsServers.mapNotNull { it.hostAddress })
                    metered =
                        !capabilities.hasCapability(
                            NetworkCapabilities.NET_CAPABILITY_NOT_METERED,
                        )
                }
        }
        return NetworkInterfaceListIterator(result)
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun readWIFIState(): WIFIState? = null

    override fun systemCertificates(): StringIterator {
        val certificates = mutableListOf<String>()
        runCatching {
            val keyStore = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
            val aliases = keyStore.aliases()
            while (aliases.hasMoreElements()) {
                val certificate = keyStore.getCertificate(aliases.nextElement()) as? X509Certificate
                    ?: continue
                val encoded = Base64.encodeToString(certificate.encoded, Base64.NO_WRAP)
                certificates +=
                    "-----BEGIN CERTIFICATE-----\n" +
                    encoded.chunked(64).joinToString("\n") +
                    "\n-----END CERTIFICATE-----\n"
            }
        }
        return StringListIterator(certificates)
    }

    override fun clearDNSCache() = Unit

    override fun sendNotification(notification: Notification) {
        service.showCoreNotification(
            notification.title.orEmpty(),
            notification.body.orEmpty(),
        )
    }

    override fun close() {
        defaultNetworkMonitor.close()
    }

    private fun StringIterator.toStringList(): List<String> {
        val values = mutableListOf<String>()
        while (hasNext()) values += next()
        return values
    }

    private fun JavaNetworkInterface.interfaceFlags(): Int {
        var result = 0
        if (isUp) result = result or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
        if (isLoopback) result = result or OsConstants.IFF_LOOPBACK
        if (isPointToPoint) result = result or OsConstants.IFF_POINTOPOINT
        if (supportsMulticast()) result = result or OsConstants.IFF_MULTICAST
        return result
    }

    companion object {
        private const val TAG = "AikoBox/platform"
    }
}
