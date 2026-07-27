package com.aikobox.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.nekohasekai.libbox.InterfaceUpdateListener
import java.net.NetworkInterface

class DefaultNetworkMonitor(context: Context) : AutoCloseable {
    private val connectivityManager =
        context.getSystemService(ConnectivityManager::class.java)
    private val lock = Any()
    private var listener: InterfaceUpdateListener? = null
    private var registered = false
    private var currentNetwork: Network? = null
    private val callbackHandler = Handler(Looper.getMainLooper())
    private val networkRequest =
        NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()

    private val callback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                currentNetwork = network
                notify(network)
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) = notify(network)

            override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) =
                notify(network)

            override fun onLost(network: Network) {
                if (currentNetwork == network) {
                    currentNetwork = null
                    listener?.updateDefaultInterface("", -1, false, false)
                }
            }
        }

    fun start(newListener: InterfaceUpdateListener) {
        synchronized(lock) {
            listener = newListener
            if (!registered) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    connectivityManager.registerBestMatchingNetworkCallback(
                        networkRequest,
                        callback,
                        callbackHandler,
                    )
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    connectivityManager.requestNetwork(
                        networkRequest,
                        callback,
                        callbackHandler,
                    )
                } else {
                    connectivityManager.requestNetwork(networkRequest, callback)
                }
                registered = true
            }
        }
    }

    fun stop(oldListener: InterfaceUpdateListener) {
        synchronized(lock) {
            if (listener !== oldListener) return
            listener = null
            unregister()
        }
    }

    private fun notify(network: Network) {
        if (network != currentNetwork) return
        val link = connectivityManager.getLinkProperties(network) ?: return
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return
        val name = link.interfaceName ?: return
        val index = runCatching { NetworkInterface.getByName(name)?.index ?: -1 }.getOrDefault(-1)
        listener?.updateDefaultInterface(
            name,
            index,
            !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
            !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED),
        )
    }

    private fun unregister() {
        if (!registered) return
        runCatching { connectivityManager.unregisterNetworkCallback(callback) }
        currentNetwork = null
        registered = false
    }

    override fun close() {
        synchronized(lock) {
            listener = null
            unregister()
        }
    }
}
