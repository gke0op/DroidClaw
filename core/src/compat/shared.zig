const std = @import("std");
const builtin = @import("builtin");

pub const Io = std.Io;
pub const Allocator = std.mem.Allocator;

var fallback_threaded: Io.Threaded = .init_single_threaded;
var process_io: ?Io = null;
var process_args: ?std.process.Args = null;
var process_environ: ?std.process.Environ = null;

pub fn initProcess(init: std.process.Init) void {
    process_io = init.io;
    process_args = init.minimal.args;
    process_environ = init.minimal.environ;
}

pub fn initProcessMinimal(init: std.process.Init.Minimal) void {
    process_args = init.args;
    process_environ = init.environ;
}

pub fn io() Io {
    if (builtin.is_test) return std.testing.io;
    const base = if (process_io) |current| current else fallback_threaded.io();
    if (comptime builtin.abi.isAndroid()) return androidIo(base);
    return base;
}

// Android has no /etc/resolv.conf, so Zig's own resolver (resolv.conf -> 127.0.0.1:53) fails
// with NameServerFailure. Swap only Io.VTable.netLookup for bionic getaddrinfo (netd).
// Verified on device (Samsung S24 Ultra, Android 15): stock lookup fails, this one works.
var android_vtable: Io.VTable = undefined;
var android_base: ?Io = null;

fn androidIo(base: Io) Io {
    if (android_base == null or android_base.?.vtable != base.vtable) {
        android_vtable = base.vtable.*;
        android_vtable.netLookup = bionicLookup;
        android_base = base;
    }
    return .{ .userdata = base.userdata, .vtable = &android_vtable };
}

fn bionicLookup(
    userdata: ?*anyopaque,
    host_name: Io.net.HostName,
    resolved: *Io.Queue(Io.net.HostName.LookupResult),
    options: Io.net.HostName.LookupOptions,
) Io.net.HostName.LookupError!void {
    _ = userdata;
    const qio = android_base.?;
    defer resolved.close(qio);
    var name_buf: [Io.net.HostName.max_len + 1]u8 = undefined;
    @memcpy(name_buf[0..host_name.bytes.len], host_name.bytes);
    name_buf[host_name.bytes.len] = 0;
    var port_buf: [8]u8 = undefined;
    const port_c = std.fmt.bufPrintSentinel(&port_buf, "{d}", .{options.port}, 0) catch unreachable;
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    var res: ?*std.c.addrinfo = null;
    if (@intFromEnum(std.c.getaddrinfo(@ptrCast(&name_buf), port_c.ptr, &hints, &res)) != 0)
        return error.UnknownHostName;
    defer if (res) |r| std.c.freeaddrinfo(r);
    var it = res;
    while (it) |info| : (it = info.next) {
        const sa = info.addr orelse continue;
        const addr: Io.net.IpAddress = switch (sa.family) {
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
        resolved.putOne(qio, .{ .address = addr }) catch return error.UnknownHostName;
    }
    if (options.canonical_name_buffer) |buf| {
        @memcpy(buf[0..host_name.bytes.len], host_name.bytes);
        resolved.putOne(qio, .{ .canonical_name = .{ .bytes = buf[0..host_name.bytes.len] } }) catch {};
    }
}

pub fn environ() std.process.Environ {
    if (process_environ) |env| return env;
    return switch (builtin.os.tag) {
        .windows, .freestanding, .other => .{ .block = .global },
        .wasi, .emscripten => if (builtin.link_libc) blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        } else .{ .block = .global },
        else => blk: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        },
    };
}

pub fn argsAlloc(allocator: Allocator) ![]const [:0]const u8 {
    const args = process_args orelse return error.MissingProcessContext;
    var iter = try args.iterateAllocator(allocator);
    defer iter.deinit();

    var list: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
    }

    while (iter.next()) |arg| {
        try list.append(allocator, try allocator.dupeSentinel(u8, arg, 0));
    }

    return try list.toOwnedSlice(allocator);
}

pub fn argsFree(allocator: Allocator, args: []const [:0]const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}
