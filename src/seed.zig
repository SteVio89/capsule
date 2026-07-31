//! Materialises the run's agent-state directory.
//!
//! The token and the endpoint let the agent *ask* about its issue. Nothing so far makes
//! it do so — and agents forgetting the tracker exists is the failure this whole design
//! is built to prevent. So the MCP config, the policy settings and an opening instruction
//! are written for it.
//!
//! **Agent state is per run**, copied from the profile's at start and discarded at end.
//! A shared `~/.claude` would be worse than untidy: several projects share a profile, so
//! a run token written there is visible to — and overwritten by — the next run in that
//! profile, and an agent silently authenticated as someone else's run is the worst
//! failure this design can produce.
//!
//! No file in the user's project is touched. That is hard constraint 1.

const std = @import("std");
const Io = std.Io;

pub const comment_guard = @embedFile("assets/hooks/comment-guard.sh");
pub const quality_gate = @embedFile("assets/hooks/quality-gate.sh");
pub const statusline = @embedFile("assets/statusline.sh");

pub const Run = struct {
    issue_short: []const u8,
    issue_title: []const u8,
    project_dir: []const u8,
    mcp_port: u16,
};

/// The MCP server entry, written to `.claude.json` in the run's agent-state directory —
/// user scope, not a `.mcp.json` at the project root, which would put capsule's own
/// configuration inside the user's repository.
///
/// The token is referenced as `${CAPSULE_RUN_TOKEN}` rather than substituted. Claude Code
/// expands environment variables in `headers`, so the file on disk carries no secret at
/// all and the token lives only in the process environment.
pub fn mcpConfig(arena: std.mem.Allocator, run: Run) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{{
        \\  "mcpServers": {{
        \\    "capsule": {{
        \\      "type": "http",
        \\      "url": "http://localhost:{d}/mcp",
        \\      "headers": {{
        \\        "Authorization": "Bearer ${{CAPSULE_RUN_TOKEN}}"
        \\      }}
        \\    }}
        \\  }}
        \\}}
        \\
    , .{run.mcp_port});
}

/// Named the issue, told to fetch it. The body is deliberately *not* pasted in: fetching
/// it means later edits are visible, and gives the agent a reason to call the tool at all.
pub fn instructions(arena: std.mem.Allocator, run: Run) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\# This session
        \\
        \\You are working on one issue, {s} — "{s}" — and only that one. You cannot
        \\switch to another; the session is bound to it.
        \\
        \\Call `get_issue` first. It returns the current description and the project's
        \\accumulated memory. Do not work from this file's summary of the title: the
        \\description may have been edited since this session started.
        \\
        \\Call `set_state` when you start, when you get stuck, and when you are done. On
        \\`blocked` and `ready_for_review` a comment is required — your session history is
        \\not kept after this run, so that note and your commits are the only things that
        \\survive it.
        \\
        \\Commit as you go. The branch is yours and nothing leaves this machine until a
        \\human merges it.
        \\
    , .{ run.issue_short, run.issue_title });
}

/// Two layers, merged with **capsule policy winning**.
///
/// Not one blob the user edits in place: that would be clobbered on every release, and
/// policy would be silently overridable in the meantime.
///
/// Pure, so the precedence rule is testable without a filesystem.
pub fn mergeSettings(
    arena: std.mem.Allocator,
    user_template: []const u8,
) ![]const u8 {
    var merged: std.json.ObjectMap = .empty;

    if (user_template.len > 0) {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, user_template, .{})) |parsed| {
            switch (parsed) {
                .object => |o| {
                    var it = o.iterator();
                    while (it.next()) |entry| {
                        try merged.put(arena, entry.key_ptr.*, entry.value_ptr.*);
                    }
                },
                else => {},
            }
        } else |_| {}
    }

    // Then policy, overwriting whatever the template said.
    //
    // bypassPermissions is not a convenience setting: it is the point of the tool. A
    // container, in a VM, on a git replica with no remotes, with every change gated
    // behind `run review`. If permission prompts are still wanted here, the isolation is
    // not earning its cost.
    try merged.put(arena, "permissions", .{ .object = blk: {
        var permissions: std.json.ObjectMap = .empty;
        try permissions.put(arena, "defaultMode", .{ .string = "bypassPermissions" });
        break :blk permissions;
    } });

    try merged.put(arena, "statusLine", .{ .object = blk: {
        var line: std.json.ObjectMap = .empty;
        try line.put(arena, "type", .{ .string = "command" });
        try line.put(arena, "command", .{ .string = "~/.claude/statusline.sh" });
        break :blk line;
    } });

    // Hooks are merged, not replaced: the template's own hooks keep running, and the
    // policy hooks are appended per event so they cannot be configured away. Claude Code
    // runs every matching entry, so append is the union.
    try merged.put(arena, "hooks", .{ .object = try mergeHooks(arena, merged.get("hooks")) });

    return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = merged }, .{ .whitespace = .indent_2 });
}

fn mergeHooks(arena: std.mem.Allocator, user_hooks: ?std.json.Value) !std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    if (user_hooks) |value| switch (value) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| try out.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        },
        else => {},
    };

    const policy = try hookConfig(arena);
    var it = policy.iterator();
    while (it.next()) |entry| {
        const event = entry.key_ptr.*;
        const policy_items = entry.value_ptr.*.array.items;

        var combined = std.json.Array.init(arena);
        if (out.get(event)) |existing| switch (existing) {
            .array => |user_items| try combined.appendSlice(user_items.items),
            else => {},
        };
        try combined.appendSlice(policy_items);
        try out.put(arena, event, .{ .array = combined });
    }
    return out;
}

fn hookConfig(arena: std.mem.Allocator) !std.json.ObjectMap {
    var hooks: std.json.ObjectMap = .empty;

    // MultiEdit is in the matcher deliberately. Omitting it is how the host version let
    // every multi-edit through without a word.
    try hooks.put(arena, "PostToolUse", try matcherArray(
        arena,
        "Write|Edit|MultiEdit",
        "~/.claude/hooks/comment-guard.sh",
    ));
    try hooks.put(arena, "Stop", try matcherArray(arena, "", "~/.claude/hooks/quality-gate.sh"));
    return hooks;
}

fn matcherArray(arena: std.mem.Allocator, matcher: []const u8, command: []const u8) !std.json.Value {
    var hook: std.json.ObjectMap = .empty;
    try hook.put(arena, "type", .{ .string = "command" });
    try hook.put(arena, "command", .{ .string = command });

    // std.json.Array is a *managed* list — it carries its allocator, unlike ObjectMap.
    var inner = std.json.Array.init(arena);
    try inner.append(.{ .object = hook });

    var entry: std.json.ObjectMap = .empty;
    if (matcher.len > 0) try entry.put(arena, "matcher", .{ .string = matcher });
    try entry.put(arena, "hooks", .{ .array = inner });

    var outer = std.json.Array.init(arena);
    try outer.append(.{ .object = entry });
    return .{ .array = outer };
}

/// Writes the whole tree. `dir` is a host-side directory that bash then ships to the VM;
/// keeping the templating in one language means bash never has to build JSON.
pub fn writeTree(
    arena: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    user_template: []const u8,
    run: Run,
) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    try cwd.createDirPath(io, try std.fmt.allocPrint(arena, "{s}/hooks", .{dir}));

    try writeFile(arena, io, dir, ".claude.json", try mcpConfig(arena, run), false);
    try writeFile(arena, io, dir, "settings.json", try mergeSettings(arena, user_template), false);
    try writeFile(arena, io, dir, "INSTRUCTIONS.md", try instructions(arena, run), false);
    try writeFile(arena, io, dir, "statusline.sh", statusline, true);
    try writeFile(arena, io, dir, "hooks/comment-guard.sh", comment_guard, true);
    try writeFile(arena, io, dir, "hooks/quality-gate.sh", quality_gate, true);
}

fn writeFile(
    arena: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    name: []const u8,
    contents: []const u8,
    executable: bool,
) !void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
    var file = try Io.Dir.cwd().createFile(io, path, .{
        // A hook that is written but not executable is a hook that silently never runs,
        // which is the same failure mode as a matcher that matches nothing.
        //
        // The enum is open (`_`), so the mode goes in numerically. 0o777 rather than
        // 0o755 because POSIX file creation is masked by umask, exactly as `default_file`
        // is 0o666 rather than 0o644.
        .permissions = if (executable) @enumFromInt(0o777) else .default_file,
    });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(contents);
    try w.interface.flush();
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const example = Run{
    .issue_short = "018f2a1c",
    .issue_title = "rate limiter drops bursts",
    .project_dir = "/home/agent/work/api",
    .mcp_port = 8765,
};

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "the mcp config names the http transport and carries no secret" {
    var a = testArena();
    defer a.deinit();
    const config = try mcpConfig(a.allocator(), example);

    // "http", not "streamable-http" or "sse": an entry with a url and no type is read as
    // a stdio server and skipped.
    try testing.expect(std.mem.indexOf(u8, config, "\"type\": \"http\"") != null);
    try testing.expect(std.mem.indexOf(u8, config, "localhost:8765/mcp") != null);

    // The token is referenced, never substituted — Claude Code expands env vars in
    // headers, so the file itself is not a secret.
    try testing.expect(std.mem.indexOf(u8, config, "${CAPSULE_RUN_TOKEN}") != null);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), config, .{});
    try testing.expect(parsed.object.get("mcpServers").?.object.get("capsule") != null);
}

test "policy wins over the user's template" {
    var a = testArena();
    defer a.deinit();
    const merged = try mergeSettings(a.allocator(),
        \\{"theme":"dark","permissions":{"defaultMode":"default"},"model":"opus"}
    );

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), merged, .{});
    // Preferences survive.
    try testing.expectEqualStrings("dark", parsed.object.get("theme").?.string);
    try testing.expectEqualStrings("opus", parsed.object.get("model").?.string);
    // Policy overrides the template's attempt to turn bypass off.
    try testing.expectEqualStrings(
        "bypassPermissions",
        parsed.object.get("permissions").?.object.get("defaultMode").?.string,
    );
}

test "a missing or broken template still yields usable settings" {
    var a = testArena();
    defer a.deinit();
    for ([_][]const u8{ "", "not json", "[]", "null" }) |template| {
        const merged = try mergeSettings(a.allocator(), template);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), merged, .{});
        try testing.expectEqualStrings(
            "bypassPermissions",
            parsed.object.get("permissions").?.object.get("defaultMode").?.string,
        );
    }
}

test "both hooks are configured, and MultiEdit is in the matcher" {
    var a = testArena();
    defer a.deinit();
    const merged = try mergeSettings(a.allocator(), "");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), merged, .{});
    const hooks = parsed.object.get("hooks").?.object;

    const post = hooks.get("PostToolUse").?.array.items[0].object;
    try testing.expectEqualStrings("Write|Edit|MultiEdit", post.get("matcher").?.string);
    try testing.expect(hooks.get("Stop") != null);
}

test "the template's own hooks survive the merge, alongside policy's" {
    var a = testArena();
    defer a.deinit();
    const merged = try mergeSettings(a.allocator(),
        \\{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"mine.sh"}]}],
        \\          "PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"pre.sh"}]}]}}
    );
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), merged, .{});
    const hooks = parsed.object.get("hooks").?.object;

    // The user's PostToolUse entry comes first, policy's is appended after it.
    const post = hooks.get("PostToolUse").?.array.items;
    try testing.expectEqual(@as(usize, 2), post.len);
    try testing.expectEqualStrings("Bash", post[0].object.get("matcher").?.string);
    try testing.expectEqualStrings("Write|Edit|MultiEdit", post[1].object.get("matcher").?.string);
    // An event policy does not use passes through untouched.
    try testing.expect(hooks.get("PreToolUse") != null);
    // Policy-only events are still there.
    try testing.expect(hooks.get("Stop") != null);
}

test "the instruction names the issue and says to fetch it" {
    var a = testArena();
    defer a.deinit();
    const text = try instructions(a.allocator(), example);
    try testing.expect(std.mem.indexOf(u8, text, "018f2a1c") != null);
    try testing.expect(std.mem.indexOf(u8, text, "get_issue") != null);
    try testing.expect(std.mem.indexOf(u8, text, "set_state") != null);
    // The body is fetched, not pasted: an inlined copy would go stale and would remove
    // the agent's reason to call the tool.
    try testing.expect(std.mem.indexOf(u8, text, "may have been edited") != null);
}

test "the shipped hooks gate on CAPSULE_PROJECT_DIR, not a host path" {
    // The host versions checked $cwd against ~/code, which never matches in a container
    // and so failed open — the guard silently never fired.
    try testing.expect(std.mem.indexOf(u8, comment_guard, "CAPSULE_PROJECT_DIR") != null);
    try testing.expect(std.mem.indexOf(u8, quality_gate, "CAPSULE_PROJECT_DIR") != null);

    // No hardcoded host path in the *logic*. Comments may name the old one — both scripts
    // explain the bug on purpose — so only executable lines are checked.
    for ([_][]const u8{ comment_guard, quality_gate }) |script| {
        var lines = std.mem.splitScalar(u8, script, '\n');
        while (lines.next()) |line| {
            const code = std.mem.trimStart(u8, line, " \t");
            if (code.len == 0 or code[0] == '#') continue;
            if (std.mem.indexOf(u8, code, "/code") != null) {
                std.debug.print("host path in executable line: {s}\n", .{line});
                return error.HardcodedHostPath;
            }
        }
    }
}

test "the quality gate bounds its output and cannot trap the session" {
    try testing.expect(std.mem.indexOf(u8, quality_gate, "tail -100") != null);
    try testing.expect(std.mem.indexOf(u8, quality_gate, "attempts") != null);
}

test "the shipped scripts depend only on what the image actually has" {
    // The image re-locks nixpkgs weekly, so anything beyond these drifts away.
    for ([_][]const u8{ "python", "perl", "node", "rg ", "fd " }) |absent| {
        try testing.expect(std.mem.indexOf(u8, comment_guard, absent) == null);
        try testing.expect(std.mem.indexOf(u8, quality_gate, absent) == null);
        try testing.expect(std.mem.indexOf(u8, statusline, absent) == null);
    }
}

test "the status line asks the http endpoint, not MCP" {
    // A shell script cannot practically speak JSON-RPC with a handshake on every render.
    try testing.expect(std.mem.indexOf(u8, statusline, "/status") != null);
    try testing.expect(std.mem.indexOf(u8, statusline, "CAPSULE_RUN_TOKEN") != null);
}
