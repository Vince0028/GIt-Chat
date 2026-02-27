package com.example.git_chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.gitchat/wifi_direct"
    private val TAG = "WifiDirect"

    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private var weCreatedGroup = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        manager = getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        channel = manager?.initialize(this, Looper.getMainLooper(), null)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "createGroup" -> createGroup(result)
                "removeGroup" -> removeGroup(result)
                "getConnectionInfo" -> getConnectionInfo(result)
                "discoverAndConnect" -> discoverAndConnect(result)
                "bindToP2pNetwork" -> bindToP2pNetwork(result)
                "unbindNetwork" -> unbindNetwork(result)
                else -> result.notImplemented()
            }
        }

        // Register receiver for Wi-Fi Direct state changes
        val intentFilter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        Log.d(TAG, "P2P connection changed")
                    }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, intentFilter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, intentFilter)
        }
    }

    /** Caller creates a Wi-Fi Direct group — becomes group owner at 192.168.49.1 */
    private fun createGroup(result: MethodChannel.Result) {
        val mgr = manager
        val ch = channel
        if (mgr == null || ch == null) {
            result.error("NO_SERVICE", "WifiP2pManager not available", null)
            return
        }

        mgr.createGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Group created — owner at 192.168.49.1")
                weCreatedGroup = true
                // Give the group a moment to fully form
                Handler(Looper.getMainLooper()).postDelayed({
                    getConnectionInfo(result)
                }, 1500)
            }

            override fun onFailure(reason: Int) {
                val msg = when (reason) {
                    WifiP2pManager.P2P_UNSUPPORTED -> "P2P unsupported"
                    WifiP2pManager.BUSY -> "Busy (group may already exist)"
                    WifiP2pManager.ERROR -> "Internal error"
                    else -> "Unknown ($reason)"
                }
                Log.e(TAG, "createGroup failed: $msg")
                // If busy, a group might already exist — try to use it
                if (reason == WifiP2pManager.BUSY) {
                    getConnectionInfo(result)
                } else {
                    result.error("CREATE_FAILED", msg, null)
                }
            }
        })
    }

    /** Callee discovers nearby Wi-Fi Direct peers and connects to the first one */
    private fun discoverAndConnect(result: MethodChannel.Result) {
        val mgr = manager
        val ch = channel
        if (mgr == null || ch == null) {
            result.error("NO_SERVICE", "WifiP2pManager not available", null)
            return
        }

        Log.d(TAG, "Starting peer discovery...")
        mgr.discoverPeers(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Discovery started, waiting for peers...")
                // Try multiple times with increasing delays (discovery can be slow)
                attemptFindAndConnect(mgr, ch, result, attempt = 1, maxAttempts = 5)
            }

            override fun onFailure(reason: Int) {
                Log.e(TAG, "Discovery failed: $reason, trying existing connection")
                // Fall back to existing connection info
                getConnectionInfo(result)
            }
        })
    }

    /** Retry peer discovery and connection up to maxAttempts times */
    private fun attemptFindAndConnect(
        mgr: WifiP2pManager,
        ch: WifiP2pManager.Channel,
        result: MethodChannel.Result,
        attempt: Int,
        maxAttempts: Int
    ) {
        // Increasing delay: 3s, 5s, 7s, 9s, 11s
        val delayMs = (1000 + attempt * 2000).toLong()
        Log.d(TAG, "Attempt $attempt/$maxAttempts — waiting ${delayMs}ms for peers...")
        
        Handler(Looper.getMainLooper()).postDelayed({
            mgr.requestPeers(ch) { peers ->
                val deviceList = peers.deviceList.toList()
                Log.d(TAG, "Attempt $attempt: found ${deviceList.size} peers")

                if (deviceList.isEmpty()) {
                    if (attempt < maxAttempts) {
                        // Retry — discovery might take longer
                        attemptFindAndConnect(mgr, ch, result, attempt + 1, maxAttempts)
                    } else {
                        Log.d(TAG, "No peers after $maxAttempts attempts, trying existing connection")
                        getConnectionInfo(result)
                    }
                    return@requestPeers
                }

                // Connect to the first available peer (the group owner)
                val device = deviceList[0]
                Log.d(TAG, "Connecting to: ${device.deviceName} (${device.deviceAddress})")
                val config = WifiP2pConfig().apply {
                    deviceAddress = device.deviceAddress
                }

                mgr.connect(ch, config, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        Log.d(TAG, "Connect initiated, waiting for group...")
                        Handler(Looper.getMainLooper()).postDelayed({
                            getConnectionInfo(result)
                        }, 2000)
                    }

                    override fun onFailure(reason: Int) {
                        Log.e(TAG, "Connect failed: $reason, trying existing connection")
                        getConnectionInfo(result)
                    }
                })
            }
        }, delayMs)
    }

    /** Get Wi-Fi Direct connection info (IPs) */
    private fun getConnectionInfo(result: MethodChannel.Result) {
        val mgr = manager
        val ch = channel
        if (mgr == null || ch == null) {
            result.error("NO_SERVICE", "WifiP2pManager not available", null)
            return
        }

        mgr.requestConnectionInfo(ch) { info: WifiP2pInfo? ->
            val map = HashMap<String, Any>()
            if (info != null && info.groupFormed) {
                map["groupFormed"] = true
                map["isGroupOwner"] = info.isGroupOwner
                map["groupOwnerAddress"] = info.groupOwnerAddress?.hostAddress ?: "192.168.49.1"
                Log.d(TAG, "✅ Group formed! owner=${info.isGroupOwner} addr=${info.groupOwnerAddress?.hostAddress}")
            } else {
                map["groupFormed"] = false
                map["isGroupOwner"] = false
                map["groupOwnerAddress"] = ""
                Log.d(TAG, "❌ No group formed yet")
            }
            result.success(map)
        }
    }

    /** Remove the Wi-Fi Direct group (cleanup after call) */
    private fun removeGroup(result: MethodChannel.Result) {
        val mgr = manager
        val ch = channel
        if (mgr == null || ch == null) {
            result.success(true)
            return
        }

        // Only remove if we created it
        if (!weCreatedGroup) {
            result.success(true)
            return
        }

        mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Group removed")
                weCreatedGroup = false
                result.success(true)
            }

            override fun onFailure(reason: Int) {
                Log.e(TAG, "removeGroup failed: $reason")
                weCreatedGroup = false
                result.success(false)
            }
        })
    }

    /**
     * Bind the entire process to the Wi-Fi Direct (p2p0) network.
     * This forces WebRTC (and all new sockets) to use the p2p0 interface
     * instead of loopback. Without this, ICE only gathers 127.0.0.1 candidates.
     */
    private fun bindToP2pNetwork(result: MethodChannel.Result) {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val allNetworks = cm.allNetworks
            Log.d(TAG, "Looking for p2p network among ${allNetworks.size} networks...")

            var p2pNetwork: Network? = null
            for (network in allNetworks) {
                val lp: LinkProperties? = cm.getLinkProperties(network)
                val caps: NetworkCapabilities? = cm.getNetworkCapabilities(network)
                val ifaceName = lp?.interfaceName ?: "unknown"
                Log.d(TAG, "Network: iface=$ifaceName caps=$caps")

                // Match p2p interface or 192.168.49.x address
                if (ifaceName.contains("p2p")) {
                    p2pNetwork = network
                    Log.d(TAG, "Found p2p network on interface $ifaceName")
                    break
                }
                // Also check link addresses for 192.168.49.x
                lp?.linkAddresses?.forEach { la ->
                    val addr = la.address
                    if (addr is Inet4Address && addr.hostAddress?.startsWith("192.168.49") == true) {
                        p2pNetwork = network
                        Log.d(TAG, "Found p2p network via IP ${addr.hostAddress} on $ifaceName")
                    }
                }
                if (p2pNetwork != null) break
            }

            if (p2pNetwork != null) {
                val bound = cm.bindProcessToNetwork(p2pNetwork)
                Log.d(TAG, "bindProcessToNetwork: $bound")
                result.success(bound)
            } else {
                Log.w(TAG, "No p2p network found — listing all interfaces for debug")
                for (network in allNetworks) {
                    val lp = cm.getLinkProperties(network)
                    Log.d(TAG, "  iface=${lp?.interfaceName} addrs=${lp?.linkAddresses}")
                }
                result.success(false)
            }
        } catch (e: Exception) {
            Log.e(TAG, "bindToP2pNetwork error: ${e.message}")
            result.success(false)
        }
    }

    /** Unbind the process from any specific network (restore default routing) */
    private fun unbindNetwork(result: MethodChannel.Result) {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.bindProcessToNetwork(null)
            Log.d(TAG, "Process unbound from p2p network")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "unbindNetwork error: ${e.message}")
            result.success(false)
        }
    }

    override fun onDestroy() {
        try {
            // Ensure we unbind on destroy
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.bindProcessToNetwork(null)
        } catch (_: Exception) {}
        try {
            receiver?.let { unregisterReceiver(it) }
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
