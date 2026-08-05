//! `capsule gc` — what the VM holds for a project that the host may reclaim:
//! `branches` are the replica branches `vm gc` may delete, `runs` every run directory
//! and container `run reset` must remove. This reports; the deleting happens host-side.

const std = @import("std");
const Io = std.Io;

const ids = @import("../../id.zig");
const protocol = @import("../../protocol.zig");
const store_mod = @import("../../store.zig");
const params_mod = @import("../params.zig");

const Daemon = @import("../../daemon.zig").Daemon;

pub fn dispatch(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
) !void {
    const verb = request.method["gc.".len..];
    const scope = try params_mod.project(d, arena, w, request) orelse return;
    const project_id = scope.id;

    if (std.mem.eql(u8, verb, "branches")) {
        const done = try d.store.listIssues(arena, project_id, .done);
        try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
        for (done, 0..) |row, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"capsule/{s}\"", .{ids.toHex(row.id)});
        }
        return w.writeAll("]}\n");
    }

    if (std.mem.eql(u8, verb, "runs")) {
        // Every run, not a page of them: one missed row orphans a seed directory in
        // the VM forever, and `run.list`'s display limit would do exactly that.
        const rows = try d.store.listRuns(arena, project_id, std.math.maxInt(u32));
        try w.print("{{\"id\":{d},\"ok\":true,\"result\":[", .{request.id});
        for (rows, 0..) |row, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"dir\":\"{s}\",\"container\":\"{s}\"}}", .{
                ids.toHex(row.id)[0..12],
                try store_mod.containerName(arena, row.id),
            });
        }
        return w.writeAll("]}\n");
    }

    return protocol.writeErr(w, request.id, .unknown_method, request.method);
}
