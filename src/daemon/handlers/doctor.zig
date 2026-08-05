//! `capsule doctor` — replay every issue's log and report where it disagrees with the
//! cached state.

const std = @import("std");
const Io = std.Io;

const api = @import("../../api.zig");
const doctor_mod = @import("../../doctor.zig");
const ids = @import("../../id.zig");
const protocol = @import("../../protocol.zig");
const params_mod = @import("../params.zig");

const Daemon = @import("../../daemon.zig").Daemon;

pub fn dispatch(
    d: *Daemon,
    arena: std.mem.Allocator,
    w: *Io.Writer,
    request: protocol.Request,
) !void {
    const scope = try params_mod.project(d, arena, w, request) orelse return;
    const project_id = scope.id;

    const rows = try d.store.listIssues(arena, project_id, null);

    var findings: std.ArrayList(api.DoctorFinding) = .empty;
    for (rows) |row| {
        const events = try d.store.listEvents(arena, row.id);
        const report = try doctor_mod.check(arena, row, events);
        if (report.verdict == .ok) continue;

        // `short` hands back a fixed array by value, so it has to be copied rather than
        // pointed at — the array does not outlive this iteration.
        const short = ids.short(row.id);
        try findings.append(arena, .{
            .short = try arena.dupe(u8, &short),
            .title = row.title,
            .verdict = report.verdict,
            .recorded = row.state,
            .replayed = report.replayed,
            .unreadable = report.unreadable,
        });
    }

    return api.writeOk(w, request.id, api.DoctorReport{
        .checked = rows.len,
        .findings = findings.items,
    });
}
