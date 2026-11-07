//! nullhermes survival probe — native side (Zig 0.17.1).
//! One heartbeat = three network tests, returned as one log fragment:
//!   A  stock std.http.Client (Zig's own DNS: /etc/resolv.conf -> 127.0.0.1:53)
//!   B  bionic getaddrinfo (Android's netd resolver)
//!   C  std.http.Client on an Io whose netLookup is swapped for getaddrinfo
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;

const probe_host = "connectivitycheck.gstatic.com";
const probe_url = "https://connectivitycheck.gstatic.com/generate_204";

var threaded: Io.Threaded = .init_single_threaded;
var patched_vtable: Io.VTable = undefined;

fn stockIo() Io {
    return threaded.io();
}

fn patchedIo() Io {
    const base = threaded.io();
    patched_vtable = base.vtable.*;
    patched_vtable.netLookup = bionicLookup;
    return .{ .userdata = base.userdata, .vtable = &patched_vtable };
}

/// Drop-in replacement for Io.VTable.netLookup that asks the platform
/// resolver instead of parsing /etc/resolv.conf (absent on Android).
fn bionicLookup(
    userdata: ?*anyopaque,
    host_name: net.HostName,
    resolved: *Io.Queue(net.HostName.LookupResult),
    options: net.HostName.LookupOptions,
) net.HostName.LookupError!void {
    _ = userdata;
    const io = stockIo();
    defer resolved.close(io);

    var name_buf: [net.HostName.max_len + 1]u8 = undefined;
    @memcpy(name_buf[0..host_name.bytes.len], host_name.bytes);
    name_buf[host_name.bytes.len] = 0;
    var port_buf: [8]u8 = undefined;
    const port_c = std.fmt.bufPrintSentinel(&port_buf, "{d}", .{options.port}, 0) catch unreachable;

    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    var res: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(@ptrCast(&name_buf), port_c.ptr, &hints, &res);
    if (@intFromEnum(rc) != 0) return error.UnknownHostName;
    defer if (res) |r| std.c.freeaddrinfo(r);

    var it = res;
    while (it) |info| : (it = info.next) {
        const sa = info.addr orelse continue;
        const addr: net.IpAddress = switch (sa.family) {
            std.c.AF.INET => blk: {
                const in: *const std.c.sockaddr.in = @ptrCast(@alignCast(sa));
                break :blk .{ .ip4 = .{ .bytes = @bitCast(in.addr), .port = std.mem.bigToNative(u16, in.port) } };
            },
            std.c.AF.INET6 => blk: {
                const in6: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(sa));
                break :blk .{ .ip6 = .{ .bytes = in6.addr, .port = std.mem.bigToNative(u16, in6.port) } };
            },
            else => continue,
        };
        if (options.family) |fam| if (fam != std.meta.activeTag(addr)) continue;
        resolved.putOne(io, .{ .address = addr }) catch return error.UnknownHostName;
    }
    if (options.canonical_name_buffer) |buf| {
        @memcpy(buf[0..host_name.bytes.len], host_name.bytes);
        resolved.putOne(io, .{ .canonical_name = .{ .bytes = buf[0..host_name.bytes.len] } }) catch {};
    }
}

fn nowMs() i64 {
    return std.Io.Clock.awake.now(stockIo()).toMilliseconds();
}

fn httpTest(w: *std.Io.Writer, label: []const u8, io: Io) void {
    const t0 = nowMs();
    var client: std.http.Client = .{ .allocator = std.heap.c_allocator, .io = io };
    defer client.deinit();
    if (client.fetch(.{ .location = .{ .url = probe_url }, .keep_alive = false })) |r| {
        w.print("{s}=http{d}/{d}ms ", .{ label, @intFromEnum(r.status), nowMs() - t0 }) catch {};
    } else |err| {
        w.print("{s}=ERR:{s}/{d}ms ", .{ label, @errorName(err), nowMs() - t0 }) catch {};
    }
}

fn dnsTest(w: *std.Io.Writer) void {
    const t0 = nowMs();
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.socktype = std.c.SOCK.STREAM;
    var res: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(probe_host, "443", &hints, &res);
    if (@intFromEnum(rc) != 0) {
        w.print("B=ERR:eai{d}/{d}ms ", .{ @intFromEnum(rc), nowMs() - t0 }) catch {};
        return;
    }
    var n: usize = 0;
    var it = res;
    while (it) |i| : (it = i.next) n += 1;
    std.c.freeaddrinfo(res.?);
    w.print("B=ok{d}addr/{d}ms ", .{ n, nowMs() - t0 }) catch {};
}

/// Runs all tests; writes a NUL-terminated line into `out`.
pub fn heartbeat(out: []u8) [:0]const u8 {
    var w: std.Io.Writer = .fixed(out[0 .. out.len - 1]);
    httpTest(&w, "A", stockIo());
    dnsTest(&w);
    httpTest(&w, "C", patchedIo());
    const n = w.end;
    out[n] = 0;
    return out[0..n :0];
}

// ---- JNI (only for the Android shared library) ----
const JNIEnv = *const *const [233]?*const anyopaque;
const NewStringUTF = *const fn (JNIEnv, [*:0]const u8) callconv(.c) ?*anyopaque;

fn jniHeartbeat(env: JNIEnv, cls: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = cls;
    var buf: [512]u8 = undefined;
    const line = heartbeat(&buf);
    const f: NewStringUTF = @ptrCast(@alignCast(env.*[167].?)); // JNINativeInterface.NewStringUTF
    return f(env, line.ptr);
}

comptime {
    if (builtin.output_mode == .Lib)
        @export(&jniHeartbeat, .{ .name = "Java_dev_gke0op_hprobe_Native_heartbeat" });
}

pub fn main() void {
    var buf: [512]u8 = undefined;
    std.debug.print("{s}\n", .{heartbeat(&buf)});
}
