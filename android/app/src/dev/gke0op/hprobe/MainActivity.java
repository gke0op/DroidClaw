package dev.gke0op.hprobe;

import android.app.Activity;
import android.content.ContentValues;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.MediaStore;
import android.provider.Settings;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import java.io.OutputStream;
import java.nio.file.Files;
import java.util.List;

public class MainActivity extends Activity {
    private TextView out;
    private android.widget.EditText keyField;
    private SharedPreferences p;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        p = getSharedPreferences("p", 0);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        TextView title = new TextView(this);
        title.setText("nullhermes probe v0.5");
        title.setTextSize(22);
        col.addView(title);

        add(col, "1 · Start heartbeat", v -> start());
        add(col, "2 · Allow running in background (battery exemption)", v -> exempt());
        add(col, "3 · Samsung: Battery → Background usage limits → Never sleeping apps → +", v -> samsung());
        Button modeBtn = new Button(this);
        modeBtn.setAllCaps(false);
        modeBtn.setText("Wake mode: " + p.getString("mode", "sleep") + "  (tap to change)");
        modeBtn.setOnClickListener(v -> {
            String cur = p.getString("mode", "sleep");
            String next = cur.equals("sleep") ? "alarm" : cur.equals("alarm") ? "wakelock" : "sleep";
            p.edit().putString("mode", next).apply();
            modeBtn.setText("Wake mode: " + next + "  (tap to change)");
            Log.line(this, "MODE " + next);
            if (p.getBoolean("running", false)) { stopService(new Intent(this, HeartbeatService.class)); start(); }
        });
        col.addView(modeBtn);
        add(col, "4 · Run bundled nullclaw (Zig 0.17 port)", v -> runNullclaw());
        keyField = new android.widget.EditText(this);
        keyField.setHint("OpenRouter key for step 5 (kept in memory only)");
        keyField.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);
        col.addView(keyField);
        add(col, "5 · Agent turn on this phone (nullclaw → OpenRouter)", v -> agentTurn());
        add(col, "Export log to Downloads", v -> export());
        add(col, "Refresh", v -> refresh());
        add(col, "Stop heartbeat", v -> stop());

        out = new TextView(this);
        out.setTextSize(11);
        out.setTextIsSelectable(true);
        col.addView(out);
        ScrollView sv = new ScrollView(this);
        sv.addView(col);
        // Android 15 forces edge-to-edge: pad the content by the system bar insets.
        sv.setOnApplyWindowInsetsListener((v, in) -> {
            android.graphics.Insets s = in.getInsets(android.view.WindowInsets.Type.systemBars());
            col.setPadding(24 + s.left, 24 + s.top, 24 + s.right, 24 + s.bottom);
            return android.view.WindowInsets.CONSUMED;
        });
        setContentView(sv);
        refresh();
    }

    private void add(LinearLayout col, String label, android.view.View.OnClickListener l) {
        Button btn = new Button(this);
        btn.setText(label);
        btn.setAllCaps(false);
        btn.setOnClickListener(l);
        col.addView(btn);
    }

    private void start() {
        if (Build.VERSION.SDK_INT >= 33)
            requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, 1);
        p.edit().putBoolean("running", true).apply();
        startForegroundService(new Intent(this, HeartbeatService.class).putExtra("why", "user"));
        toast("Heartbeat started");
        out.postDelayed(this::refresh, 15_000);
    }

    private void stop() {
        p.edit().putBoolean("running", false).apply();
        stopService(new Intent(this, HeartbeatService.class));
        Log.line(this, "USER_STOP");
        refresh();
    }

    private void exempt() {
        PowerManager pm = getSystemService(PowerManager.class);
        if (pm.isIgnoringBatteryOptimizations(getPackageName())) { toast("Already exempt"); return; }
        startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:" + getPackageName())));
    }

    private void samsung() {
        String[][] targets = {
                {"com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"},
                {"com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"},
        };
        for (String[] t : targets) {
            try {
                startActivity(new Intent().setClassName(t[0], t[1]));
                toast("Background usage limits → Never sleeping apps → add 'nullhermes probe'");
                Log.line(this, "SAMSUNG_SETTINGS opened " + t[1]);
                return;
            } catch (Exception ignored) {}
        }
        Log.line(this, "SAMSUNG_SETTINGS not found, fell back to app details");
        startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:" + getPackageName())));
        toast("Battery → Unrestricted");
    }

    private void export() {
        try {
            ContentValues v = new ContentValues();
            v.put(MediaStore.Downloads.DISPLAY_NAME, "hprobe-" + Build.MODEL + "-" + System.currentTimeMillis() + ".log");
            v.put(MediaStore.Downloads.MIME_TYPE, "text/plain");
            Uri u = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
            try (OutputStream o = getContentResolver().openOutputStream(u)) {
                o.write(Files.readAllBytes(Log.file(this).toPath()));
            }
            toast("Saved to Downloads");
        } catch (Exception e) { toast("Export failed: " + e); }
    }

    private void refresh() {
        try {
            List<String> l = Files.readAllLines(Log.file(this).toPath());
            StringBuilder s = new StringBuilder("lines=" + l.size() + "\n");
            for (int i = l.size() - 1; i >= Math.max(0, l.size() - 40); i--) s.append(l.get(i)).append("\n\n");
            out.setText(s);
        } catch (Exception e) { out.setText("No log yet. Tap 1, then 2 and 3."); }
    }

    /** Executes the nullclaw binary shipped as lib/arm64-v8a/libnullclaw.so (exec from nativeLibraryDir). */
    private void runNullclaw() {
        toast("Running nullclaw…");
        new Thread(() -> {
            String bin = getApplicationInfo().nativeLibraryDir + "/libnullclaw.so";
            for (String[] args : new String[][]{{"--version"}, {"--help"}, {"status"}}) {
                try {
                    String[] cmd = new String[args.length + 1];
                    cmd[0] = bin; System.arraycopy(args, 0, cmd, 1, args.length);
                    ProcessBuilder pb = new ProcessBuilder(cmd).redirectErrorStream(true);
                    pb.environment().put("HOME", getFilesDir().getAbsolutePath());
                    long t0 = System.nanoTime();
                    Process pr = pb.start();
                    byte[] outb = pr.getInputStream().readAllBytes();
                    int code = pr.waitFor();
                    String o = new String(outb).replace('\n', ' ');
                    if (o.length() > 600) o = o.substring(0, 600) + "…";
                    Log.line(this, "NULLCLAW " + String.join(" ", args) + " exit=" + code
                            + " ms=" + (System.nanoTime() - t0) / 1_000_000 + " out=" + o);
                } catch (Exception e) {
                    Log.line(this, "NULLCLAW " + String.join(" ", args) + " EXEC_FAIL " + e);
                }
            }
            runOnUiThread(this::refresh);
        }).start();
    }

    /** One real agent turn: nullclaw agent -m ... with the key passed only as an env var. */
    private void agentTurn() {
        String key = keyField.getText().toString().trim();
        if (key.isEmpty()) { toast("Paste the key first"); return; }
        toast("Agent turn running…");
        new Thread(() -> {
            String bin = getApplicationInfo().nativeLibraryDir + "/libnullclaw.so";
            try {
                ProcessBuilder pb = new ProcessBuilder(bin, "agent", "-m",
                        "Reply with one short sentence: which device and OS are you running on, judging by your environment?",
                        "--provider", "openrouter", "--model", "stealth/crouton-alpha").redirectErrorStream(true);
                pb.environment().put("HOME", getFilesDir().getAbsolutePath());
                pb.environment().put("OPENROUTER_API_KEY", key);
                long t0 = System.nanoTime();
                Process pr = pb.start();
                byte[] outb = pr.getInputStream().readAllBytes();
                int code = pr.waitFor();
                String o = new String(outb).replace('\n', ' ');
                if (o.length() > 800) o = o.substring(o.length() - 800);
                Log.line(this, "AGENT exit=" + code + " ms=" + (System.nanoTime() - t0) / 1_000_000 + " out=" + o);
            } catch (Exception e) {
                Log.line(this, "AGENT EXEC_FAIL " + e);
            }
            runOnUiThread(this::refresh);
        }).start();
    }

    private void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_LONG).show(); }
}
