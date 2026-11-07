package dev.gke0op.hprobe;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context c, Intent i) {
        if (!c.getSharedPreferences("p", 0).getBoolean("running", false)) return;
        Log.line(c, "BOOT_RECEIVER action=" + i.getAction());
        try {
            c.startForegroundService(new Intent(c, HeartbeatService.class).putExtra("why", "boot"));
        } catch (Exception e) {
            Log.line(c, "BOOT_START_FAILED " + e);
        }
    }
}
