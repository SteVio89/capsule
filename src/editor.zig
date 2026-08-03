//! `$VISUAL` / `$EDITOR` writeback, git-style: spawn on a temp file, wait, inspect.

const std = @import("std");
const Io = std.Io;

/// What the user did, in the order the checks must happen.
pub const Outcome = enum {
    /// Opened and closed without changing anything — the common case, someone reading.
    unchanged,
    /// Emptied the buffer. Git's convention for "cancel", and the only intuitive one once
    /// you are already inside the editor.
    aborted,
    /// The editor exited non-zero.
    discarded,
    changed,
};

/// Pure, and the reason the exit code alone is not enough: `:q!` exits 0, so a hash of
/// the buffer before and after is the only way to tell "read it" from "edited it".
pub fn classify(before: []const u8, after: []const u8, exit_code: u8) Outcome {
    if (exit_code != 0) return .discarded;
    const cleaned = stripComments(after);
    if (std.mem.trim(u8, cleaned, " \t\r\n").len == 0) return .aborted;
    if (std.mem.eql(u8, std.mem.trim(u8, cleaned, "\n"), std.mem.trim(u8, stripComments(before), "\n"))) {
        return .unchanged;
    }
    return .changed;
}

/// Context headers use HTML comments, not `#`: the buffer is markdown, where `#` is a
/// heading and would end up in the issue body.
pub fn stripComments(text: []const u8) []const u8 {
    var rest = text;
    while (std.mem.startsWith(u8, rest, "<!--")) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse return "";
        rest = rest[end + 1 ..];
    }
    return rest;
}

/// Drops every comment line, not just leading ones — the general case `stripComments`
/// avoids. Returns a fresh copy allocated in `arena`, which owns it.
pub fn stripCommentsAlloc(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "<!--")) continue;
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

/// `$VISUAL`, then `$EDITOR`, then a fallback. Never hardcodes one editor.
pub fn resolveEditor(environ: *const std.process.Environ.Map) []const u8 {
    if (environ.get("VISUAL")) |v| if (v.len > 0) return v;
    if (environ.get("EDITOR")) |v| if (v.len > 0) return v;
    return "vi";
}

pub const Result = struct {
    outcome: Outcome,
    /// Only meaningful when `outcome == .changed`.
    text: []const u8 = "",
};

/// Spawns the editor on a temp file seeded with `seed`, waits, and classifies the result.
pub fn editText(
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    seed: []const u8,
    tmp_dir: []const u8,
) !Result {
    var path: []const u8 = undefined;
    var file: Io.File = undefined;
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        var entropy: [8]u8 = undefined;
        io.random(&entropy);
        path = try std.fmt.allocPrint(arena, "{s}/capsule-edit-{x}.md", .{ tmp_dir, &entropy });
        file = Io.Dir.cwd().createFile(io, path, .{
            .exclusive = true,
            .permissions = @enumFromInt(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => if (attempts < 8) continue else return err,
            else => return err,
        };
        break;
    }
    var keep_for_recovery = false;
    defer if (!keep_for_recovery) Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(seed);
        try w.interface.flush();
    }

    const editor = resolveEditor(environ);

    const tty: ?Io.File = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch null;
    defer if (tty) |t| t.close(io);
    const child_stdio: std.process.SpawnOptions.StdIo =
        if (tty) |t| .{ .file = t } else .inherit;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", try std.fmt.allocPrint(arena, "{s} \"$1\"", .{editor}), "sh", path },
        .stdin = child_stdio,
        .stdout = child_stdio,
        .stderr = child_stdio,
    });
    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => 1,
    };

    const after = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
        keep_for_recovery = true;
        std.log.err("could not read the edited buffer back ({t}) — your text is still at {s}", .{ err, path });
        return err;
    };
    const outcome = classify(seed, after, exit_code);
    return .{
        .outcome = outcome,
        .text = if (outcome == .changed) try stripCommentsAlloc(arena, after) else "",
    };
}

const testing = std.testing;

test "a non-zero exit discards, whatever the buffer says" {
    try testing.expectEqual(Outcome.discarded, classify("before", "totally different", 1));
    try testing.expectEqual(Outcome.discarded, classify("before", "", 130));
}

test "an untouched buffer is unchanged, not a write" {
    try testing.expectEqual(Outcome.unchanged, classify("body text\n", "body text\n", 0));
    try testing.expectEqual(Outcome.unchanged, classify("body text", "body text\n", 0));
}

test "an emptied buffer aborts, as git does" {
    try testing.expectEqual(Outcome.aborted, classify("body", "", 0));
    try testing.expectEqual(Outcome.aborted, classify("body", "   \n\n\t", 0));
}

test "a real edit is a change" {
    try testing.expectEqual(Outcome.changed, classify("before\n", "after\n", 0));
}

test "quitting without saving exits zero, so the hash is what catches it" {
    try testing.expectEqual(Outcome.unchanged, classify("seeded\n", "seeded\n", 0));
}

test "a context header does not count as content" {
    const seed = "<!-- capsule: edit the body below -->\nreal body\n";
    try testing.expectEqual(Outcome.unchanged, classify(seed, seed, 0));
    try testing.expectEqual(Outcome.aborted, classify(seed, "<!-- capsule: edit the body below -->\n", 0));
}

test "comment stripping removes only comment lines" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const out = try stripCommentsAlloc(a.allocator(),
        \\<!-- a header -->
        \\real line
        \\  <!-- indented comment -->
        \\another line
    );
    try testing.expectEqualStrings("real line\nanother line\n", out);
}

test "editor resolution prefers VISUAL, then EDITOR, then vi" {
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();

    try testing.expectEqualStrings("vi", resolveEditor(&map));
    try map.put("EDITOR", "nano");
    try testing.expectEqualStrings("nano", resolveEditor(&map));
    try map.put("VISUAL", "hx");
    try testing.expectEqualStrings("hx", resolveEditor(&map));
    try map.put("VISUAL", "");
    try testing.expectEqualStrings("nano", resolveEditor(&map));
}
