//! Method name to handler. Holds the one lock for the whole call: at one user's scale
//! the contention is nil and the reasoning is trivial, which is the better trade.

const std = @import("std");
const Io = std.Io;

const api = @import("../api.zig");
const protocol = @import("../protocol.zig");
const views = @import("views.zig");

const board = @import("handlers/board.zig");
const doctor = @import("handlers/doctor.zig");
const gc = @import("handlers/gc.zig");
const issue = @import("handlers/issue.zig");
const memory = @import("handlers/memory.zig");
const project = @import("handlers/project.zig");
const run = @import("handlers/run.zig");

const Daemon = @import("../daemon.zig").Daemon;

pub fn dispatch(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
) !void {
    d.mutex.lockUncancelable(d.io);
    defer d.mutex.unlock(d.io);

    if (std.mem.eql(u8, request.method, "ping")) {
        return protocol.writeOk(w, request.id, "{\"pong\":true}");
    }

    if (std.mem.eql(u8, request.method, "daemon.status")) {
        var body: std.ArrayList(u8) = .empty;
        var bw = std.Io.Writer.Allocating.fromArrayList(arena, &body);
        try bw.writer.writeAll("{\"socket\":");
        try std.json.Stringify.encodeJsonString(d.socket_path, .{}, &bw.writer);
        // Not `catch 0`: a store that cannot be read is indistinguishable from a fresh
        // install if it answers zero, and `daemon status` is where someone looks first.
        const projects = d.store.countProjects() catch |err| {
            std.log.err("daemon.status could not read the store: {t}", .{err});
            return protocol.writeErr(w, request.id, .internal, "the store could not be read");
        };
        try bw.writer.print(",\"projects\":{d},\"endpoint\":\"{s}\"}}", .{
            projects,
            if (d.http_up.load(.acquire)) "up" else "down",
        });
        return protocol.writeOk(w, request.id, bw.written());
    }

    if (std.mem.startsWith(u8, request.method, "project.")) {
        return project.dispatch(d, arena, w, request);
    }

    if (std.mem.startsWith(u8, request.method, "run.")) {
        return run.dispatch(d, arena, w, request);
    }

    if (std.mem.startsWith(u8, request.method, "memory.")) {
        return memory.dispatch(d, arena, w, request);
    }

    if (std.mem.startsWith(u8, request.method, "gc.")) {
        return gc.dispatch(d, arena, w, request);
    }

    if (std.mem.startsWith(u8, request.method, "issue.")) {
        return issue.dispatch(d, arena, w, request);
    }

    if (std.mem.eql(u8, request.method, "world.get")) {
        return api.writeOk(w, request.id, try views.worldModel(d, arena));
    }

    if (std.mem.eql(u8, request.method, "doctor.check")) {
        return doctor.dispatch(d, arena, w, request);
    }

    if (std.mem.eql(u8, request.method, "board.get")) {
        return board.dispatch(d, arena, w, request);
    }

    if (std.mem.eql(u8, request.method, "daemon.stop")) {
        d.quit.store(true, .release);
        return protocol.writeOk(w, request.id, "{\"stopping\":true}");
    }

    return protocol.writeErr(w, request.id, .unknown_method, request.method);
}

const testing = std.testing;

test "every method the protocol declares reaches a handler" {
    // Drives the real router rather than checking it against a second list of names,
    // which is the only form of this that cannot drift: a method added to `api.all` and
    // never routed answers `unknown_method`, and that is exactly what fails here.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var d = try Daemon.init(testing.allocator, io, .{
        .socket_path = "/nonexistent/capsule.sock",
        .db_path = ":memory:",
        .ssh = .{ .vm_host = "core@localhost", .control_dir = "/nonexistent" },
    });
    defer d.deinit();

    // An empty store and no params, so most methods refuse — `no_project` and
    // `bad_params` are fine. The one answer that is not is "there is no such method".
    inline for (api.all) |method| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var out: std.ArrayList(u8) = .empty;
        var buffered = std.Io.Writer.Allocating.fromArrayList(arena.allocator(), &out);
        try dispatch(&d, arena.allocator(), &buffered.writer, .{
            .id = 1,
            .method = method.name,
            .params = .null,
        });

        if (std.mem.indexOf(u8, buffered.written(), "\"code\":\"unknown_method\"") != null) {
            std.debug.print("'{s}' is declared in api.all but the router has no branch\n", .{method.name});
            return error.UnroutedMethod;
        }
    }
}
