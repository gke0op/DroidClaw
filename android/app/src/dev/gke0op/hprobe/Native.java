package dev.gke0op.hprobe;

final class Native {
    static { System.loadLibrary("hprobe"); }
    /** Runs the A/B/C network tests in the Zig library; returns one log fragment. */
    static native String heartbeat();
    /** Asks Mainline DHT nodes which ip:port they see us at, from one UDP socket (NAT type test). */
    static native String nat();
}
