//! The command taxonomy, as data.
//!
//! In bash this was ~280 lines: nine `dispatch_*` functions with the same twelve-line
//! shape, ten `usage_*` heredocs that had to be edited in lockstep with them, and a guard
//! (`host_only`, `need_daemon`, `vm_reachable`, `qemu_only`, `need_remote`) repeated by
//! hand at the top of thirty-eight command functions. Nothing checked that the three
//! agreed; `test/capsule-test.sh` grepped the help text for verb names precisely because
//! there was no other way to tell.
//!
//! Here the taxonomy is one array. Help is rendered from it, dispatch resolves against
//! it, and the guards are fields rather than statements — so a command cannot be added
//! without declaring what it needs, and the help cannot drift from what exists.

const std = @import("std");
const Writer = std.Io.Writer;

/// What must be true before a command runs. Checked once by the dispatcher rather than
/// restated at the top of each handler.
pub const Needs = struct {
    /// Refused inside a capsule container. Everything but the `env` verbs, which are the
    /// one group an agent runs against its own checkout.
    host: bool = false,
    /// `capsuled` must answer, or the user is told to start it.
    daemon: bool = false,
    /// The VM must be reachable. Never boots one — booting takes minutes and is an
    /// explicit act.
    vm: bool = false,
    /// Drives the local qemu VM specifically, so it refuses when `CAPSULE_VM_HOST` names
    /// a machine capsule does not own.
    qemu: bool = false,
    /// The `vm` git remote must exist, which means `run start` has bootstrapped once.
    remote: bool = false,
};

pub const Command = struct {
    group: []const u8,
    /// Empty for the two commands that take no verb: `board` and `login`.
    verb: []const u8 = "",
    /// Argument spelling for the help line, e.g. `"[issue]"`.
    args: []const u8 = "",
    summary: []const u8,
    needs: Needs = .{},
    /// False while this verb still lives in the bash CLI. The dispatcher says so plainly
    /// rather than failing in some confusing way, and `portedCount` below reports the
    /// progress of the move so it cannot be guessed at.
    ported: bool = false,

    pub fn isBare(self: Command) bool {
        return self.verb.len == 0;
    }
};

/// How much of the taxonomy has moved out of bash, so "how far along is this" has one
/// answer that cannot drift from the table it counts.
pub fn portedCount() usize {
    var n: usize = 0;
    for (&commands) |*c| {
        if (c.ported) n += 1;
    }
    return n;
}

pub const Group = struct {
    name: []const u8,
    summary: []const u8,
    /// Shown under the group's own help, below the verb table.
    note: []const u8 = "",
};

pub const groups = [_]Group{
    .{ .name = "project", .summary = "which repositories capsule knows about", .note = "Registration is explicit and writes nothing into the repository — a project is a row in the host's store. A profile belongs to the project, not to a run." },
    .{ .name = "env", .summary = "devshell flake for this project — the only group that works inside a capsule", .note = "Everything but 'init' works inside a capsule as well as on the host." },
    .{ .name = "vm", .summary = "the machine the agent runs on" },
    .{ .name = "image", .summary = "the container image the agent runs in" },
    .{ .name = "issue", .summary = "the backlog for this project", .note = "Omit the id and a picker opens. Ids resolve by unique prefix, as git resolves a short SHA, so the short form is enough." },
    .{ .name = "memory", .summary = "what a fresh agent could not work out for itself", .note = "The cap is 40 active and it is enforced: accepting at the cap requires deactivating one in the same pass." },
    .{ .name = "run", .summary = "hand work to an agent and take it back" },
    .{ .name = "daemon", .summary = "the host service everything else reads from" },
    .{ .name = "board", .summary = "the dashboard" },
    .{ .name = "login", .summary = "authenticate the agent CLI for a profile" },
};

/// Every command capsule offers. The `needs` here were lifted from the bash guards one by
/// one; the test at the bottom pins them so a port cannot quietly drop one.
pub const commands = [_]Command{
    .{ .group = "project", .verb = "add", .args = "[--profile <name>]", .summary = "register $PWD (default profile: default)", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "project", .verb = "list", .summary = "every registered project", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "project", .verb = "profile", .args = "<name>", .summary = "change this project's profile", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "project", .verb = "rm", .args = "[--force]", .summary = "unregister; refuses while issues exist", .needs = .{ .host = true, .daemon = true }, .ported = true },

    .{ .group = "env", .verb = "init", .args = "[lang] [name]", .summary = "scaffold flake.nix, .envrc, .gitignore, git repo (host only)", .needs = .{ .host = true }, .ported = true },
    .{ .group = "env", .verb = "add", .args = "<pkg>...", .summary = "add packages to flake.nix", .ported = true },
    .{ .group = "env", .verb = "rm", .args = "<pkg>...", .summary = "remove packages from flake.nix", .ported = true },
    .{ .group = "env", .verb = "update", .summary = "nix flake update, then reload", .ported = true },
    .{ .group = "env", .verb = "reload", .summary = "direnv reload", .ported = true },

    .{ .group = "vm", .verb = "status", .summary = "where the agent host is, and whether it's up", .needs = .{ .host = true }, .ported = true },
    .{ .group = "vm", .verb = "ssh", .args = "[cmd...]", .summary = "ssh into it, or run one command there", .needs = .{ .host = true, .vm = true }, .ported = true },
    .{ .group = "vm", .verb = "gc", .summary = "prune containers/images, collect nix garbage", .needs = .{ .host = true, .vm = true }, .ported = true },
    .{ .group = "vm", .verb = "start", .summary = "boot it, downloading the disk if needed", .needs = .{ .host = true, .qemu = true }, .ported = true },
    .{ .group = "vm", .verb = "stop", .summary = "power it off (disk is kept)", .needs = .{ .host = true, .qemu = true, .vm = true }, .ported = true },
    .{ .group = "vm", .verb = "disk", .summary = "actual vs virtual size of the VM disk", .needs = .{ .host = true, .qemu = true }, .ported = true },
    .{ .group = "vm", .verb = "destroy", .summary = "delete the VM disk (asks first)", .needs = .{ .host = true, .qemu = true }, .ported = true },

    .{ .group = "image", .verb = "pull", .summary = "pull the published image, dropping the stale nix volume", .needs = .{ .host = true, .vm = true }, .ported = true },
    .{ .group = "image", .verb = "build", .summary = "build it locally instead, from this checkout", .needs = .{ .host = true, .vm = true }, .ported = true },

    .{ .group = "issue", .verb = "new", .args = "<title>", .summary = "create one; the body opens in $EDITOR", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "issue", .verb = "list", .args = "[state]", .summary = "every issue, or only those in one state", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "issue", .verb = "edit", .args = "[id]", .summary = "edit the body in $EDITOR", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "issue", .verb = "rename", .args = "[id] <title>", .summary = "change the title (no editor: it is one line)", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "issue", .verb = "comment", .args = "[id]", .summary = "add a note to the event log", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "issue", .verb = "state", .args = "[id] <state>", .summary = "set it by hand: open, in_progress, blocked, ready_for_review", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "issue", .verb = "triage", .summary = "review everything an agent filed, in one buffer", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "issue", .verb = "archive", .args = "[id] -m <reason>", .summary = "set it aside, with a reason (reversible)", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "issue", .verb = "reopen", .args = "[id]", .summary = "bring an archived issue back", .needs = .{ .host = true, .daemon = true }, .ported = true },

    .{ .group = "memory", .verb = "list", .summary = "every memory and its state", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "memory", .verb = "review", .summary = "review proposals and prune the active set", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "memory", .verb = "new", .summary = "write one by hand", .needs = .{ .host = true, .daemon = true }, .ported = true },

    .{ .group = "run", .verb = "start", .args = "[issue-id]", .summary = "dispatch an issue to an agent (a picker opens without one)", .needs = .{ .host = true, .daemon = true, .vm = true }, .ported = true },
    .{ .group = "run", .verb = "attach", .summary = "reconnect to the live run", .needs = .{ .host = true, .daemon = true, .vm = true }, .ported = true },
    .{ .group = "run", .verb = "end", .summary = "end the live run and remove its container", .needs = .{ .host = true, .daemon = true }, .ported = true },
    .{ .group = "run", .verb = "reset", .args = "[--force]", .summary = "drop this project's replica, run dirs and 'vm' remote", .needs = .{ .host = true, .daemon = true, .vm = true }, .ported = true },
    .{ .group = "run", .verb = "list", .summary = "runs on this project, newest first", .needs = .{ .host = true, .daemon = true }, .ported = true },
    // `push` reaches the daemon through `issue_branch`, which the bash guard never
    // declared — with capsuled down it failed with a raw error instead of the remedy.
    .{ .group = "run", .verb = "push", .args = "[issue-id]", .summary = "push HEAD onto that issue's branch in the replica", .needs = .{ .host = true, .daemon = true, .remote = true }, .ported = true },
    .{ .group = "run", .verb = "fetch", .summary = "git fetch vm — refs only, nothing else changes", .needs = .{ .host = true, .remote = true }, .ported = true },
    .{ .group = "run", .verb = "review", .args = "[issue-id]", .summary = "review that issue's branch in tuicr (git log -p without it)", .needs = .{ .host = true, .daemon = true, .remote = true }, .ported = true },
    .{ .group = "run", .verb = "merge", .args = "[issue-id]", .summary = "squash into this branch, mark the issue done, re-sync", .needs = .{ .host = true, .daemon = true, .remote = true }, .ported = true },

    .{ .group = "daemon", .verb = "start", .summary = "start it, via the user service if one is installed", .needs = .{ .host = true }, .ported = true },
    .{ .group = "daemon", .verb = "stop", .summary = "stop it", .needs = .{ .host = true }, .ported = true },
    .{ .group = "daemon", .verb = "status", .summary = "whether it is up, and what it is holding", .needs = .{ .host = true }, .ported = true },

    .{ .group = "board", .summary = "VM, issues, memory and waiting branches — read-only", .needs = .{ .host = true, .daemon = true } },
    .{ .group = "login", .args = "[profile]", .summary = "a container to authenticate the agent CLI in", .needs = .{ .host = true, .vm = true }, .ported = true },
};

pub const Resolution = union(enum) {
    /// A command to run.
    command: *const Command,
    /// `capsule <group>` with no verb, or `capsule <group> help`.
    group_help: *const Group,
    /// `capsule`, `capsule help`, `-h`, `--help`.
    root_help,
    unknown_group: []const u8,
    unknown_verb: struct { group: *const Group, verb: []const u8 },
};

/// Resolves argv (without the program name) to what should happen.
pub fn resolve(args: []const []const u8) Resolution {
    if (args.len == 0) return .root_help;

    const first = args[0];
    if (first.len == 0 or
        std.mem.eql(u8, first, "help") or
        std.mem.eql(u8, first, "-h") or
        std.mem.eql(u8, first, "--help")) return .root_help;

    const group = findGroup(first) orelse return .{ .unknown_group = first };

    // `board` and `login` take no verb; anything after the group name is their argument.
    for (&commands) |*c| {
        if (std.mem.eql(u8, c.group, group.name) and c.isBare()) {
            return .{ .command = c };
        }
    }

    if (args.len == 1) return .{ .group_help = group };

    const verb = args[1];
    if (verb.len == 0 or std.mem.eql(u8, verb, "help")) return .{ .group_help = group };

    for (&commands) |*c| {
        if (std.mem.eql(u8, c.group, group.name) and std.mem.eql(u8, c.verb, verb)) {
            return .{ .command = c };
        }
    }
    return .{ .unknown_verb = .{ .group = group, .verb = verb } };
}

pub fn findGroup(name: []const u8) ?*const Group {
    for (&groups) |*g| {
        if (std.mem.eql(u8, g.name, name)) return g;
    }
    return null;
}

pub fn find(group: []const u8, verb: []const u8) ?*const Command {
    for (&commands) |*c| {
        if (std.mem.eql(u8, c.group, group) and std.mem.eql(u8, c.verb, verb)) return c;
    }
    return null;
}

/// Terminal decoration, disabled when stdout is not a tty so piped help stays plain.
pub const Style = struct {
    bold: []const u8 = "",
    accent: []const u8 = "",
    reset: []const u8 = "",

    pub const plain = Style{};
    pub const ansi = Style{ .bold = "\x1b[1m", .accent = "\x1b[36m", .reset = "\x1b[0m" };

    pub fn forTty(is_tty: bool) Style {
        return if (is_tty) ansi else plain;
    }
};

/// The group listing — what `capsule` alone prints.
pub fn writeRootHelp(w: *Writer, style: Style) !void {
    try w.print(
        "\n{s}capsule{s} — run coding agents in a container, on a VM, on a git replica\n\n",
        .{ style.bold, style.reset },
    );
    for (&groups) |*g| {
        try w.print("  {s}{s}{s}{s} {s}\n", .{
            style.accent,
            g.name,
            style.reset,
            padding(g.name, group_column),
            g.summary,
        });
    }
    try w.writeAll("\n'capsule <group>' lists that group's commands.\n\n");
}

/// One group's verbs. Replaces a hand-maintained heredoc per group.
pub fn writeGroupHelp(w: *Writer, group: *const Group, style: Style) !void {
    try w.print("\n{s}capsule {s}{s} — {s}\n\n", .{
        style.bold, group.name, style.reset, group.summary,
    });

    for (&commands) |*c| {
        if (!std.mem.eql(u8, c.group, group.name)) continue;
        if (c.isBare()) {
            try w.print("  {s}\n", .{c.summary});
            continue;
        }
        const spelled = if (c.args.len > 0) c.args else "";
        try w.print("  {s}{s}{s} {s}", .{ style.accent, c.verb, style.reset, spelled });
        try w.writeAll(padding2(c.verb, spelled, verb_column));
        try w.print("{s}\n", .{c.summary});
    }

    if (group.note.len > 0) try w.print("\n{s}\n", .{group.note});
    try w.writeAll("\n");
}

const group_column = 10;
const verb_column = 26;

/// Right-pads to a column without allocating, by handing back a slice of a fixed run of
/// spaces. Truncates to zero when the text already overflows the column.
fn padding(text: []const u8, column: usize) []const u8 {
    const spaces = " " ** 40;
    if (text.len >= column) return " ";
    return spaces[0 .. column - text.len];
}

fn padding2(a: []const u8, b: []const u8, column: usize) []const u8 {
    const spaces = " " ** 40;
    const used = a.len + 1 + b.len;
    if (used >= column) return " ";
    return spaces[0 .. column - used];
}

const testing = std.testing;

fn render(arena: std.mem.Allocator, comptime f: anytype, args: anytype) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var w = Writer.Allocating.fromArrayList(arena, &out);
    try @call(.auto, f, .{&w.writer} ++ args);
    return w.written();
}

test "every group in the taxonomy has at least one command" {
    for (&groups) |*g| {
        var found = false;
        for (&commands) |*c| {
            if (std.mem.eql(u8, c.group, g.name)) found = true;
        }
        if (!found) {
            std.debug.print("group '{s}' has no commands\n", .{g.name});
            return error.EmptyGroup;
        }
    }
}

test "every command belongs to a declared group" {
    for (&commands) |*c| {
        if (findGroup(c.group) == null) {
            std.debug.print("command '{s} {s}' has no group\n", .{ c.group, c.verb });
            return error.OrphanCommand;
        }
    }
}

test "no group and verb pair is declared twice" {
    for (&commands, 0..) |*a, i| {
        for (commands[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.group, b.group) and std.mem.eql(u8, a.verb, b.verb)) {
                std.debug.print("duplicate: {s} {s}\n", .{ a.group, a.verb });
                return error.DuplicateCommand;
            }
        }
    }
}

test "a bare group has exactly one command and no siblings" {
    // `board` and `login` take no verb. A group mixing bare and verbed commands would
    // make resolution ambiguous, so the shape is asserted rather than assumed.
    for (&groups) |*g| {
        var bare: usize = 0;
        var verbed: usize = 0;
        for (&commands) |*c| {
            if (!std.mem.eql(u8, c.group, g.name)) continue;
            if (c.isBare()) bare += 1 else verbed += 1;
        }
        try testing.expect(bare == 0 or (bare == 1 and verbed == 0));
    }
}

test "the root and its aliases all reach the group listing" {
    try testing.expectEqual(Resolution.root_help, resolve(&.{}));
    for ([_][]const u8{ "help", "-h", "--help", "" }) |spelling| {
        try testing.expectEqual(Resolution.root_help, resolve(&.{spelling}));
    }
}

test "a group alone opens that group's help" {
    const got = resolve(&.{"issue"});
    try testing.expectEqualStrings("issue", got.group_help.name);
    try testing.expectEqualStrings("issue", resolve(&.{ "issue", "help" }).group_help.name);
}

test "a group and verb resolve to one command" {
    const got = resolve(&.{ "issue", "list" });
    try testing.expectEqualStrings("issue", got.command.group);
    try testing.expectEqualStrings("list", got.command.verb);
}

test "the bare groups resolve without a verb and swallow their argument" {
    try testing.expectEqualStrings("board", resolve(&.{"board"}).command.group);
    try testing.expectEqualStrings("login", resolve(&.{"login"}).command.group);
    try testing.expectEqualStrings("login", resolve(&.{ "login", "work" }).command.group);
}

test "an unknown group and an unknown verb are told apart" {
    try testing.expectEqualStrings("nope", resolve(&.{"nope"}).unknown_group);
    const bad = resolve(&.{ "issue", "frobnicate" });
    try testing.expectEqualStrings("issue", bad.unknown_verb.group.name);
    try testing.expectEqualStrings("frobnicate", bad.unknown_verb.verb);
}

test "the old flat verbs are gone and do not resolve" {
    // `test/capsule-test.sh:96-101` asserted these exit 2 after the noun-verb move.
    for ([_][]const u8{ "new", "triage", "attach", "merge", "status", "reset" }) |flat| {
        switch (resolve(&.{flat})) {
            .unknown_group => {},
            else => {
                std.debug.print("'{s}' should not resolve as a group\n", .{flat});
                return error.FlatVerbResolves;
            },
        }
    }
}

test "the guard matrix matches the one the bash CLI enforced" {
    // Lifted verb by verb from `bin/capsule`'s host_only / need_daemon / vm_reachable /
    // qemu_only / need_remote calls. If a port drops a guard, this is what catches it.
    const Expected = struct { group: []const u8, verb: []const u8, needs: Needs };
    const expected = [_]Expected{
        .{ .group = "daemon", .verb = "start", .needs = .{ .host = true } },
        .{ .group = "daemon", .verb = "stop", .needs = .{ .host = true } },
        .{ .group = "daemon", .verb = "status", .needs = .{ .host = true } },
        .{ .group = "project", .verb = "add", .needs = .{ .host = true, .daemon = true } },
        .{ .group = "project", .verb = "rm", .needs = .{ .host = true, .daemon = true } },
        .{ .group = "issue", .verb = "new", .needs = .{ .host = true, .daemon = true } },
        .{ .group = "issue", .verb = "triage", .needs = .{ .host = true, .daemon = true } },
        .{ .group = "memory", .verb = "review", .needs = .{ .host = true, .daemon = true } },
        .{ .group = "board", .verb = "", .needs = .{ .host = true, .daemon = true } },
        .{ .group = "env", .verb = "init", .needs = .{ .host = true } },
        .{ .group = "run", .verb = "start", .needs = .{ .host = true, .daemon = true, .vm = true } },
        .{ .group = "run", .verb = "attach", .needs = .{ .host = true, .daemon = true, .vm = true } },
        .{ .group = "run", .verb = "reset", .needs = .{ .host = true, .daemon = true, .vm = true } },
        .{ .group = "run", .verb = "end", .needs = .{ .host = true, .daemon = true } },
        .{ .group = "run", .verb = "list", .needs = .{ .host = true, .daemon = true } },
        .{ .group = "run", .verb = "review", .needs = .{ .host = true, .daemon = true, .remote = true } },
        .{ .group = "run", .verb = "merge", .needs = .{ .host = true, .daemon = true, .remote = true } },
        .{ .group = "run", .verb = "fetch", .needs = .{ .host = true, .remote = true } },
        .{ .group = "login", .verb = "", .needs = .{ .host = true, .vm = true } },
        .{ .group = "image", .verb = "pull", .needs = .{ .host = true, .vm = true } },
        .{ .group = "image", .verb = "build", .needs = .{ .host = true, .vm = true } },
        .{ .group = "vm", .verb = "gc", .needs = .{ .host = true, .vm = true } },
        .{ .group = "vm", .verb = "status", .needs = .{ .host = true } },
        .{ .group = "vm", .verb = "disk", .needs = .{ .host = true, .qemu = true } },
        .{ .group = "vm", .verb = "ssh", .needs = .{ .host = true, .vm = true } },
        .{ .group = "vm", .verb = "stop", .needs = .{ .host = true, .qemu = true, .vm = true } },
        .{ .group = "vm", .verb = "destroy", .needs = .{ .host = true, .qemu = true } },
        .{ .group = "vm", .verb = "start", .needs = .{ .host = true, .qemu = true } },
    };

    for (expected) |e| {
        const cmd = find(e.group, e.verb) orelse {
            std.debug.print("missing command: {s} {s}\n", .{ e.group, e.verb });
            return error.MissingCommand;
        };
        testing.expectEqual(e.needs, cmd.needs) catch {
            std.debug.print("guards differ for '{s} {s}'\n", .{ e.group, e.verb });
            return error.GuardMismatch;
        };
    }
}

test "the env verbs that must work inside a container carry no host guard" {
    // The single exception to host-only, and the reason it exists: an agent runs these
    // against its own checkout, where there is no daemon socket to talk to.
    for ([_][]const u8{ "add", "rm", "update", "reload" }) |verb| {
        const cmd = find("env", verb).?;
        try testing.expect(!cmd.needs.host);
        try testing.expect(!cmd.needs.daemon);
    }
    try testing.expect(find("env", "init").?.needs.host);
}

test "everything that touches the store asks for the daemon" {
    for (&commands) |*c| {
        const store_backed =
            std.mem.eql(u8, c.group, "issue") or
            std.mem.eql(u8, c.group, "memory") or
            std.mem.eql(u8, c.group, "project") or
            std.mem.eql(u8, c.group, "board");
        if (store_backed) try testing.expect(c.needs.daemon);
    }
}

test "qemu-only commands are a subset of host-only ones" {
    for (&commands) |*c| {
        if (c.needs.qemu) try testing.expect(c.needs.host);
    }
}

/// Whether some line of `text`, once indented, begins with `word` as a whole word.
/// Counting raw occurrences would match group names inside the prose — the tagline alone
/// contains "run", "container" and "vm".
fn hasEntryFor(text: []const u8, word: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const body = std.mem.trimStart(u8, line, " ");
        if (body.len <= word.len) continue;
        if (std.mem.startsWith(u8, body, word) and body[word.len] == ' ') return true;
    }
    return false;
}

test "the root help lists every group as its own entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text = try render(arena.allocator(), writeRootHelp, .{Style.plain});
    for (&groups) |*g| {
        if (!hasEntryFor(text, g.name)) {
            std.debug.print("group '{s}' has no entry in the root help\n", .{g.name});
            return error.GroupMissingFromHelp;
        }
    }
}

test "a group's help names every one of its verbs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    for (&groups) |*g| {
        const text = try render(arena.allocator(), writeGroupHelp, .{ g, Style.plain });
        for (&commands) |*c| {
            if (!std.mem.eql(u8, c.group, g.name) or c.isBare()) continue;
            if (std.mem.indexOf(u8, text, c.verb) == null) {
                std.debug.print("'{s} {s}' is missing from its group help\n", .{ c.group, c.verb });
                return error.VerbMissingFromHelp;
            }
        }
    }
}

test "help carries no escape sequences when it is not going to a terminal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const plain = try render(arena.allocator(), writeRootHelp, .{Style.forTty(false)});
    try testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);

    const coloured = try render(arena.allocator(), writeRootHelp, .{Style.forTty(true)});
    try testing.expect(std.mem.indexOf(u8, coloured, "\x1b[") != null);
}

test "every verb's summary stays separated from its arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The failure this guards against is a summary butting straight against a long
    // argument spelling, which is what an unchecked column arithmetic produces.
    for (&groups) |*g| {
        const text = try render(arena.allocator(), writeGroupHelp, .{ g, Style.plain });
        for (&commands) |*c| {
            if (!std.mem.eql(u8, c.group, g.name) or c.isBare()) continue;
            const at = std.mem.indexOf(u8, text, c.summary) orelse continue;
            if (at < 2 or text[at - 1] != ' ' or text[at - 2] != ' ') {
                std.debug.print("'{s} {s}' summary is not separated\n", .{ c.group, c.verb });
                return error.SummaryNotSeparated;
            }
        }
    }
}
