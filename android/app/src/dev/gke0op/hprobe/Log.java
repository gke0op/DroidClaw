package dev.gke0op.hprobe;

import android.content.Context;
import java.io.File;
import java.io.FileWriter;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

final class Log {
    static File file(Context c) { return new File(c.getFilesDir(), "heartbeat.log"); }

    static synchronized void line(Context c, String s) {
        String ts = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US).format(new Date());
        try (FileWriter w = new FileWriter(file(c), true)) {
            w.write(ts + " " + s + "\n");
        } catch (Exception ignored) {}
    }
}
