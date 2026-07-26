package com.aikobox.app.service

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import androidx.core.content.ContextCompat
import com.aikobox.app.MainActivity
import com.aikobox.app.R

/**
 * Quick-settings tile: connect and disconnect without opening the app.
 *
 * **Needs a manifest entry** — see the `notDone` notes. Without it the tile never appears in
 * the quick-settings editor and this class is dead code.
 *
 * The tile lives in the UI process while the tunnel lives in `:remote`, so it learns the
 * state the same way the Flutter plugin does: it asks (`ACTION_QUERY_STATE`) and listens
 * (`ACTION_STATE`). No shared field could work here — they are different processes.
 *
 * One thing a tile cannot do is show the VPN consent dialog: that needs an Activity. When
 * consent has not been granted the tile opens the app instead of failing silently.
 */
class QuickTileService : TileService() {

    @Volatile
    private var state: String = AikoCoreContract.STATE_STOPPED

    private var receiver: BroadcastReceiver? = null

    override fun onStartListening() {
        super.onStartListening()
        val listener = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != AikoCoreContract.ACTION_STATE) return
                state = intent.getStringExtra(AikoCoreContract.EXTRA_STATE)
                    ?: AikoCoreContract.STATE_STOPPED
                render()
            }
        }
        ContextCompat.registerReceiver(
            this,
            listener,
            IntentFilter(AikoCoreContract.ACTION_STATE),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiver = listener

        // If nothing is running there is no answer, and `stopped` — the value already held —
        // is correct.
        state = AikoCoreContract.STATE_STOPPED
        render()
        AikoCoreContract.broadcast(this, Intent(AikoCoreContract.ACTION_QUERY_STATE))
    }

    override fun onStopListening() {
        receiver?.let { runCatching { unregisterReceiver(it) } }
        receiver = null
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        when (state) {
            AikoCoreContract.STATE_RUNNING,
            AikoCoreContract.STATE_STARTING,
            -> {
                AikoCoreContract.broadcast(this, Intent(AikoCoreContract.ACTION_STOP))
                state = AikoCoreContract.STATE_STOPPING
                render()
            }

            AikoCoreContract.STATE_STOPPING -> Unit

            else -> connect()
        }
    }

    private fun connect() {
        if (VpnService.prepare(this) != null) {
            // No consent yet, and a tile has no Activity to show the system dialog from.
            openApp()
            return
        }
        if (!CoreManager.activeConfig(this).isFile) {
            // Nothing to start. Sending the user somewhere they can fix that beats a tile
            // that appears to do nothing.
            openApp()
            return
        }
        try {
            // No config path: the service starts whatever the app last promoted, which is
            // the same configuration always-on VPN would use.
            ContextCompat.startForegroundService(
                this,
                AikoCoreContract.serviceIntent(this, AikoCoreContract.ACTION_START),
            )
            state = AikoCoreContract.STATE_STARTING
            render()
        } catch (e: Exception) {
            Log.e(TAG, "tile could not start the tunnel", e)
            openApp()
        }
    }

    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this,
                    REQUEST_OPEN,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun render() {
        val tile = qsTile ?: return
        tile.label = getString(R.string.tile_label)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_stat_tunnel)
        tile.state = when (state) {
            AikoCoreContract.STATE_RUNNING -> Tile.STATE_ACTIVE
            AikoCoreContract.STATE_STARTING, AikoCoreContract.STATE_STOPPING -> Tile.STATE_UNAVAILABLE
            else -> Tile.STATE_INACTIVE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = getString(
                when (state) {
                    AikoCoreContract.STATE_RUNNING -> R.string.tile_state_running
                    AikoCoreContract.STATE_STARTING -> R.string.tile_state_starting
                    AikoCoreContract.STATE_STOPPING -> R.string.tile_state_stopping
                    AikoCoreContract.STATE_FAILED -> R.string.tile_state_failed
                    else -> R.string.tile_state_stopped
                },
            )
        }
        tile.updateTile()
    }

    private companion object {
        const val TAG = "AikoQuickTile"
        const val REQUEST_OPEN = 200
    }
}
