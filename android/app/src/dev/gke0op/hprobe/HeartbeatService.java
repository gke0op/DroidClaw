package dev.gke0op.hprobe;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.os.BatteryManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.Process;
import android.os.SystemClock;
import java.io.BufferedReader;
import java.io.FileReader;

/** One process, one thread: wakes every 60 s, runs the Zig heartbeat, logs survival vitals. */
public class HeartbeatService extends Service {
    static final long PERIOD_MS = 60_000;
    private volatile boolean alive;
    private Thread loop;
    private PowerManager.WakeLock wl;
    private long seq = 0, last = 0;
    private Notification notif;
    private void goForeground() {
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        else startForeground(1, notif);
    }
    /** sleep = Thread.sleep loop (v0.3) · wakelock = loop + held CPU wakelock · alarm = exact allow-while-idle alarm chain */
    private String mode() { return getSharedPreferences("p", 0).getString("mode", "sleep"); }

    @Override public void onCreate() {
        super.onCreate();
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel("hb", "Heartbeat", NotificationManager.IMPORTANCE_LOW));
        Notification n = new Notification.Builder(this, "hb")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("nullhermes probe")
                .setContentText("Heartbeat every 60 s")
                .setOngoing(true).build();
        notif = n;
        goForeground();
        Log.line(this, "SERVICE_CREATE pid=" + Process.myPid()
                + " proc_age_s=" + (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime()) / 1000
                + " model=" + Build.MANUFACTURER + "/" + Build.MODEL + " sdk=" + Build.VERSION.SDK_INT);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && "BEAT".equals(intent.getAction())) {   // alarm mode tick
            goForeground();   // every startForegroundService() must be answered by startForeground()
            new Thread(this::alarmBeat, "beat").start();
            return START_STICKY;
        }
        String why = intent == null ? "sticky-restart" : intent.getStringExtra("why");
        Log.line(this, "START_COMMAND why=" + why + " flags=" + flags + " mode=" + mode());
        if (mode().equals("alarm")) {
            if (!alive) { alive = true; new Thread(this::alarmBeat, "beat").start(); }
            return START_STICKY;
        }
        boolean wantWl = mode().equals("wakelock");
        if (wantWl && wl == null) {
            wl = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hprobe:hb");
            wl.acquire();
        }
        if (loop == null) {
            alive = true;
            loop = new Thread(this::run, "heartbeat");
            loop.start();
        }
        return START_STICKY;
    }

    private void run() {
        while (alive) {
            beatOnce();
            try { Thread.sleep(PERIOD_MS); } catch (InterruptedException e) { break; }
        }
    }

    private synchronized void beatOnce() {
        long now = SystemClock.elapsedRealtime();
        if (last == 0) last = now;
        String net;
        try { net = Native.heartbeat(); } catch (Throwable t) { net = "NATIVE_FAIL " + t; }
        Log.line(this, "HB seq=" + (seq++) + " gap_s=" + (now - last) / 1000 + " " + vitals() + " " + net);
        last = now;
    }

    /** Alarm mode: hold a short wakelock for the beat (the alarm's own lock ends when we return), then re-arm. */
    private void alarmBeat() {
        PowerManager.WakeLock w = getSystemService(PowerManager.class)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hprobe:beat");
        w.acquire(30_000);
        try {
            beatOnce();
            if (!alive) return;
            android.app.AlarmManager am = getSystemService(android.app.AlarmManager.class);
            android.app.PendingIntent pi = android.app.PendingIntent.getForegroundService(this, 0,
                    new Intent(this, HeartbeatService.class).setAction("BEAT"),
                    android.app.PendingIntent.FLAG_IMMUTABLE | android.app.PendingIntent.FLAG_UPDATE_CURRENT);
            long at = SystemClock.elapsedRealtime() + PERIOD_MS;
            if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
                Log.line(this, "EXACT_ALARM_DENIED falling back to inexact allow-while-idle");
                am.setAndAllowWhileIdle(android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi);
            } else {
                am.setExactAndAllowWhileIdle(android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi);
            }
        } catch (Throwable t) {
            Log.line(this, "ALARM_FAIL " + t);
        } finally {
            if (w.isHeld()) w.release();
        }
    }

    private String vitals() {
        PowerManager pm = getSystemService(PowerManager.class);
        Intent b = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        int lvl = b == null ? -1 : b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
        int plug = b == null ? -1 : b.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1);
        return "pid=" + Process.myPid()
                + " up_s=" + (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime()) / 1000
                + " doze=" + pm.isDeviceIdleMode()
                + " screen=" + pm.isInteractive()
                + " exempt=" + pm.isIgnoringBatteryOptimizations(getPackageName())
                + " mode=" + mode() + " wl=" + (wl != null)
                + " batt=" + lvl + (plug > 0 ? "+" : "")
                + " rss_kb=" + rssKb();
    }

    private static long rssKb() {
        try (BufferedReader r = new BufferedReader(new FileReader("/proc/self/statm"))) {
            String[] f = r.readLine().split(" ");
            return Long.parseLong(f[1]) * 4;
        } catch (Exception e) { return -1; }
    }

    @Override public void onTaskRemoved(Intent i) { Log.line(this, "TASK_REMOVED (app swiped away)"); }

    @Override public void onDestroy() {
        alive = false;
        if (loop != null) loop.interrupt();
        getSystemService(android.app.AlarmManager.class).cancel(android.app.PendingIntent.getForegroundService(this, 0,
                new Intent(this, HeartbeatService.class).setAction("BEAT"), android.app.PendingIntent.FLAG_IMMUTABLE | android.app.PendingIntent.FLAG_UPDATE_CURRENT));
        if (wl != null && wl.isHeld()) wl.release();
        Log.line(this, "SERVICE_DESTROY");
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent i) { return null; }
}
