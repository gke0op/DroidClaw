package dev.gke0op.hprobe;

final class Native {
    static { System.loadLibrary("hprobe"); }
    /** Runs the A/B/C network tests in the Zig library; returns one log fragment. */
    static native String heartbeat();
}
