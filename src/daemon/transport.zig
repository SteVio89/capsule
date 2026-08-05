//! The unix socket: taking the start lock, clearing debris left by a dead daemon, and
//! reading one line-delimited request at a time off an accepted connection.

const std = @import("std");
const net = std.Io.net;
const Io = std.Io;

const client_mod = @import("../client.zig");
const protocol = @import("../protocol.zig");
const router = @import("router.zig");

const Daemon = @import("../daemon.zig").Daemon;

/// Wakes the HTTP thread's blocking accept so it can observe `quit` and exit. Its
/// connection is closed without a request; the accept loop treats that as routine.
pub fn nudgeHttp(d: *Daemon) void {
    const addr: net.IpAddress = .{ .ip4 = .loopback(d.ssh_config.mcp_port) };
    var stream = addr.connect(d.io, .{ .mode = .stream }) catch return;
    stream.close(d.io);
}

pub fn serveConnection(d: *Daemon, stream: net.Stream) !void {
    setSocketTimeouts(stream, 30);

    const read_buf = try d.gpa.alloc(u8, protocol.max_line + 1);
    defer d.gpa.free(read_buf);
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(d.io, read_buf);
    var writer = stream.writer(d.io, &write_buf);
    const w = &writer.interface;

    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try protocol.writeErr(w, 0, .too_large, "request line too long");
                try w.flush();
                return;
            },
            else => return,
        } orelse return;

        var arena = std.heap.ArenaAllocator.init(d.gpa);
        defer arena.deinit();

        var out: std.ArrayList(u8) = .empty;
        var buffered = std.Io.Writer.Allocating.fromArrayList(arena.allocator(), &out);

        switch (protocol.parseRequest(arena.allocator(), line)) {
            .err => |code| try protocol.writeErr(&buffered.writer, 0, code, @tagName(code)),
            .ok => |request| try router.dispatch(d, arena.allocator(), &buffered.writer, request),
        }
        try w.writeAll(buffered.written());
        try w.flush();
    }
}

/// Bounds how long a stalled peer can hold a connection open: anything in the VM can
/// reach the MCP port, and one silent connect must not wedge a serial accept loop
/// forever. Best-effort — a platform refusing the option just keeps today's behaviour.
pub fn setSocketTimeouts(stream: net.Stream, seconds: i32) void {
    // libc's setsockopt rather than std's: a peer that closed between accept and here
    // makes the call return EINVAL, and std maps EINVAL to `unreachable`, so a client
    // that connects and hangs up — a liveness probe does exactly that — panics the
    // daemon. A failed timeout is not worth dying for, so the result is ignored.
    const timeout = std.posix.timeval{ .sec = seconds, .usec = 0 };
    const len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = std.c.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout, len);
    _ = std.c.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout, len);
}

/// Takes the exclusive start lock at `<socket>.lock`, or fails with `AlreadyRunning`.
pub fn acquireStartLock(gpa: std.mem.Allocator, socket_path: []const u8) !std.posix.fd_t {
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{socket_path});
    defer gpa.free(lock_path);
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        lock_path,
        .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true },
        0o600,
    );
    errdefer _ = std.c.close(fd);
    if (std.c.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) return error.AlreadyRunning;
    return fd;
}

/// A socket file left by a daemon that died is indistinguishable from one a live daemon
/// is listening on — until you try to talk to it. Ask first: if something answers, this
/// is a second daemon and it must not start. If nothing does, the file is debris.
pub fn clearStaleSocket(io: Io, path: []const u8) !void {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        // Anything else — a permissions problem on the directory, most likely — used to
        // fall through to `bind`, which then failed with an error about the wrong thing.
        else => return err,
    };

    if (stat.kind != .unix_domain_socket) {
        Io.Dir.cwd().deleteFile(io, path) catch |err| {
            std.log.warn("cannot remove {s}, which is not a socket: {t}", .{ path, err });
        };
        return;
    }

    _ = try net.UnixAddress.init(path);

    // `client.listening` rather than a connect through `Io.net`: a stale socket with
    // nothing behind it is the expected case here, and that path dumps a stack trace in
    // Debug builds — into the daemon's own startup log, where it reads as a crash.
    if (client_mod.listening(path)) return error.AlreadyRunning;
    Io.Dir.cwd().deleteFile(io, path) catch |err| {
        std.log.warn("cannot remove the stale socket at {s}: {t}", .{ path, err });
    };
}

const testing = std.testing;

test "a socket path over the kernel limit is rejected before binding" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const long = "x" ** (net.UnixAddress.max_len + 1);
    try testing.expectError(error.NameTooLong, net.UnixAddress.init(long));
}
