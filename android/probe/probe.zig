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

// ---- NAT probe: ask Mainline DHT nodes which ip:port they see us at (BEP 42 "ip" field) ----
// One UDP socket, several DHT nodes. Same external port for every node => endpoint-independent
// mapping (hole-punchable). Different ports per node => symmetric NAT (needs a relay).
const dht_nodes = [_]struct { host: [:0]const u8, port: [:0]const u8 }{
    .{ .host = "router.bittorrent.com", .port = "6881" },
    .{ .host = "dht.transmissionbt.com", .port = "6881" },
    .{ .host = "router.utorrent.com", .port = "6881" },
    .{ .host = "dht.libtorrent.org", .port = "25401" },
};

/// KRPC node ids are exactly 20 bytes; a wrong length makes the whole ping malformed (v0.6/v0.7 bug).
const node_id = "droidclaw-natprobe!!";
comptime {
    if (node_id.len != 20) @compileError("KRPC node id must be 20 bytes");
}

fn natProbe(w: *std.Io.Writer) void {
    const c = std.c;
    const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
    if (fd < 0) { w.print("NAT=ERR:socket", .{}) catch {}; return; }
    defer _ = c.close(fd);
    const tv = c.timeval{ .sec = 2, .usec = 0 };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &tv, @sizeOf(c.timeval));
    var any = std.mem.zeroes(c.sockaddr.in);
    any.family = c.AF.INET;
    _ = c.bind(fd, @ptrCast(&any), @sizeOf(c.sockaddr.in));
    var local: c.sockaddr.in = undefined;
    var ll: c.socklen_t = @sizeOf(c.sockaddr.in);
    _ = c.getsockname(fd, @ptrCast(&local), &ll);
    w.print("NAT local_port={d}", .{std.mem.bigToNative(u16, local.port)}) catch {};

    var first_port: ?u16 = null;
    var same = true;
    var replies: usize = 0;
    for (dht_nodes) |node| {
        var hints = std.mem.zeroes(c.addrinfo);
        hints.family = c.AF.INET;
        hints.socktype = c.SOCK.DGRAM;
        var res: ?*c.addrinfo = null;
        if (@intFromEnum(c.getaddrinfo(node.host.ptr, node.port.ptr, &hints, &res)) != 0 or res == null) {
            w.print(" {s}=dns_fail", .{node.host}) catch {};
            continue;
        }
        defer c.freeaddrinfo(res.?);
        const ping = "d1:ad2:id20:" ++ node_id ++ "e1:q4:ping1:t2:nh1:y1:qe";
        _ = c.sendto(fd, ping.ptr, ping.len, 0, res.?.addr, res.?.addrlen);
        var buf: [1500]u8 = undefined;
        const n = c.recvfrom(fd, &buf, buf.len, 0, null, null);
        if (n <= 0) { w.print(" {s}=no_reply", .{node.host}) catch {}; continue; }
        const seen = parseSeenAddr(buf[0..@intCast(n)]) orelse {
            w.print(" {s}=reply_no_ip", .{node.host}) catch {};
            continue;
        };
        const ip = seen.ip;
        const port = seen.port;
        replies += 1;
        w.print(" {s}={d}.{d}.{d}.{d}:{d}", .{ node.host, ip[0], ip[1], ip[2], ip[3], port }) catch {};
        if (first_port) |fp| { if (fp != port) same = false; } else first_port = port;
    }
    const verdict = if (replies < 2) "UNKNOWN(too_few_replies)" else if (same) "SAME_PORT(punchable)" else "PORT_PER_DEST(symmetric)";
    w.print(" verdict={s}", .{verdict}) catch {};
}

/// BEP 42: KRPC replies carry the requester's address as `2:ip6:<4-byte IPv4><2-byte port>`.
fn parseSeenAddr(r: []const u8) ?struct { ip: [4]u8, port: u16 } {
    const key = "2:ip6:";
    const at = std.mem.find(u8, r, key) orelse return null;
    if (at + key.len + 6 > r.len) return null;
    const b = r[at + key.len ..][0..6];
    return .{ .ip = b[0..4].*, .port = (@as(u16, b[4]) << 8) | b[5] };
}

test "parseSeenAddr reads BEP 42 ip field" {
    const reply = "d2:ip6:" ++ [_]u8{ 85, 105, 7, 9, 0xC3, 0x50 } ++ "1:rd2:id20:abcdefghij0123456789e1:t2:nh1:y1:re";
    const got = parseSeenAddr(reply).?;
    try std.testing.expectEqual([4]u8{ 85, 105, 7, 9 }, got.ip);
    try std.testing.expectEqual(@as(u16, 50000), got.port);
    try std.testing.expect(parseSeenAddr("d1:y1:re") == null);
}

/// Runs the NAT probe; writes a NUL-terminated line into `out`.
pub fn nat(out: []u8) [:0]const u8 {
    var w: std.Io.Writer = .fixed(out[0 .. out.len - 1]);
    natProbe(&w);
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

fn jniNat(env: JNIEnv, cls: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = cls;
    var buf: [1024]u8 = undefined;
    const line = nat(&buf);
    const f: NewStringUTF = @ptrCast(@alignCast(env.*[167].?));
    return f(env, line.ptr);
}

comptime {
    if (builtin.output_mode == .Lib) {
        @export(&jniHeartbeat, .{ .name = "Java_dev_gke0op_hprobe_Native_heartbeat" });
        @export(&jniNat, .{ .name = "Java_dev_gke0op_hprobe_Native_nat" });
    }
}

pub fn main() void {
    var buf: [512]u8 = undefined;
    std.debug.print("{s}\n", .{heartbeat(&buf)});
    var nb: [1024]u8 = undefined;
    std.debug.print("{s}\n", .{nat(&nb)});
}
