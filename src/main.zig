//! capsule: one binary, three roles — daemon, MCP endpoint, dashboard client.

const std = @import("std");
const capsule = @import("capsule");

/// A panic while the board holds the terminal in raw mode on the alternate screen would
/// otherwise leave the user's shell unusable and the panic message invisible. Restore
/// first, then let the default panic do its work where it can be read.
pub const panic = std.debug.FullPanic(panicWithTerminalRestored);

fn panicWithTerminalRestored(msg: []const u8, first_trace_addr: ?usize) noreturn {
    capsule.tui.term.emergencyRestore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Dispatches on argv[1] and returns the process exit code, which bash branches on.
pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    defer out.interface.flush() catch {};

    var err_buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    defer err.interface.flush() catch {};

    var argv: std.ArrayList([]const u8) = .empty;
    var it = init.minimal.args.iterate();
    const exe_path = it.next() orelse "capsule";
    while (it.next()) |a| try argv.append(arena, a);

    const command = if (argv.items.len > 0)
        argv.items[0]
    else if (std.Io.File.stdout().isTty(init.io) catch false)
        "board"
    else {
        try capsule.cli.writeRootHelp(&out.interface, styleFor(init.io));
        return 2;
    };

    // Positional reads of everything after the command, replacing the iterator so the
    // argument list can also be resolved against the command table further down.
    const rest = if (argv.items.len > 0) argv.items[1..] else argv.items[0..0];
    var taken: usize = 0;

    if (std.mem.eql(u8, command, "version")) {
        try out.interface.print("capsule {s}\n", .{capsule.version});
        return 0;
    }

    const paths = capsule.paths.resolve(arena, .{
        .home = init.environ_map.get("HOME"),
        .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
        .capsule_socket = init.environ_map.get("CAPSULE_SOCKET"),
        .capsule_db = init.environ_map.get("CAPSULE_DB"),
    }) catch |e| {
        try err.interface.print("capsule: {t}\n", .{e});
        return 1;
    };

    // Loaded for every command, daemon included. The daemon is started by launchd or
    // systemd with a bare environment, so until now it read none of this — every knob it
    // actually uses was configurable only for the process that did not need it.
    const settings = loadSettings(arena, init, &err.interface) catch return 1;

    if (std.mem.eql(u8, command, "daemon") and rest.len == 0) {
        std.Io.Dir.cwd().createDirPath(init.io, paths.data_dir) catch {};

        std.Io.Dir.cwd().createDirPath(init.io, settings.control_dir) catch {};

        var d = capsule.daemon.Daemon.init(init.gpa, init.io, .{
            .socket_path = paths.socket,
            .db_path = try arena.dupeZ(u8, paths.db),
            .ssh = .{
                .vm_host = settings.vm_host,
                .vm_port = settings.vm_port,
                .control_dir = settings.control_dir,
                .mcp_port = settings.mcp_port,
                .image = settings.image,
            },
            .poll_interval_s = settings.poll_interval_s,
        }) catch |e| {
            try err.interface.print("capsule: cannot open {s}: {t}\n", .{ paths.db, e });
            return 1;
        };
        defer d.deinit();

        d.serve() catch |e| switch (e) {
            error.AlreadyRunning => {
                try err.interface.print(
                    "capsule: already running on {s}\n",
                    .{paths.socket},
                );
                return 1;
            },
            else => {
                try err.interface.print("capsule: {t}\n", .{e});
                return 1;
            },
        };
        return 0;
    }

    if (std.mem.eql(u8, command, "edit")) {
        const seed = take(rest, &taken) orelse "";
        const header = take(rest, &taken) orelse "";
        const seeded = if (header.len > 0)
            try std.fmt.allocPrint(arena, "{s}\n{s}", .{ header, seed })
        else
            seed;

        const tmp = init.environ_map.get("TMPDIR") orelse
            init.environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
        const result = capsule.editor.editText(arena, init.io, init.environ_map, seeded, tmp) catch |e| {
            try err.interface.print("capsule: editor failed: {t}\n", .{e});
            return 1;
        };
        switch (result.outcome) {
            .changed => {
                try out.interface.writeAll(result.text);
                return 0;
            },
            .unchanged => return 3,
            .aborted, .discarded => return 1,
        }
    }

    if (std.mem.eql(u8, command, "seed")) {
        const dir = take(rest, &taken) orelse {
            try err.interface.writeAll(
                "usage: capsule seed <dir> <issue> <title> <project-dir> [port] [theme] [editor-mode]\n",
            );
            return 2;
        };
        const issue_short = take(rest, &taken) orelse "";
        const title = take(rest, &taken) orelse "";
        const project_dir = take(rest, &taken) orelse "";
        const port = parsePort(take(rest, &taken), 8765);
        const theme = orDefault(take(rest, &taken), "dark");
        const editor_mode = orDefault(take(rest, &taken), "vim");

        const template_path = try std.fmt.allocPrint(
            arena,
            "{s}/capsule/agent-settings.json",
            .{init.environ_map.get("XDG_CONFIG_HOME") orelse
                try std.fmt.allocPrint(arena, "{s}/.config", .{init.environ_map.get("HOME") orelse "/root"})},
        );
        const template = std.Io.Dir.cwd().readFileAlloc(init.io, template_path, arena, .limited(1 << 20)) catch "";

        capsule.seed.writeTree(arena, init.io, dir, template, .{
            .issue_short = issue_short,
            .issue_title = title,
            .project_dir = project_dir,
            .mcp_port = port,
            .theme = theme,
            .editor_mode = editor_mode,
        }) catch |e| {
            try err.interface.print("capsule: cannot seed {s}: {t}\n", .{ dir, e });
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, command, "container-cmd") or std.mem.eql(u8, command, "attach-cmd")) {
        const is_attach = std.mem.eql(u8, command, "attach-cmd");
        const name = take(rest, &taken) orelse return 2;

        const cmd_argv = if (is_attach)
            try capsule.run.attachArgs(arena, name)
        else
            try capsule.run.podmanArgs(arena, .{
                .image = init.environ_map.get("CAPSULE_IMAGE") orelse "",
                .container_home = init.environ_map.get("CAPSULE_CONTAINER_HOME") orelse "/home/agent",
                .mcp_port = parsePort(init.environ_map.get("CAPSULE_MCP_PORT"), 8765),
                .container_name = name,
                .project_dir = take(rest, &taken) orelse "",
                .agent_state_dir = take(rest, &taken) orelse "",
                .env_file = take(rest, &taken) orelse "",
                .profile = take(rest, &taken) orelse "default",
                .issue_short = take(rest, &taken) orelse "",
                .git_config_path = take(rest, &taken) orelse "",
            });

        try out.interface.print("{s}\n", .{try capsule.run.commandLine(arena, cmd_argv)});
        return 0;
    }

    if (std.mem.eql(u8, command, "board")) {
        // Resolved here rather than taken from argv: bash used to compute this and pass it
        // in, so a `capsule board` run without it showed a dashboard with no project on
        // it. An explicit argument still wins, because the integration tests pass one.
        const project_params = take(rest, &taken) orelse boardParams(arena, init.io) orelse "";
        capsule.board.run(arena, init.gpa, init.io, paths.socket, project_params, exe_path) catch |e| switch (e) {
            error.DaemonNotRunning => {
                try err.interface.writeAll("capsule is not running — run 'capsule daemon start'\n");
                return 1;
            },
            error.NotATerminal => {
                try err.interface.writeAll(
                    "capsule board needs a terminal. For something scriptable, use the CLI:\n" ++
                        "  capsule world.get\n",
                );
                return 1;
            },
            else => {
                try err.interface.print("capsule: {t}\n", .{e});
                return 1;
            },
        };
        return 0;
    }

    // The user-facing CLI. A name that is not a command group falls through to the raw
    // method call below, which is what keeps `capsule ping` and `capsule world.get`
    // working for the integration tests and for anything scripting the socket directly.
    switch (capsule.cli.resolve(argv.items)) {
        .unknown_group => {},
        .root_help => {
            try capsule.cli.writeRootHelp(&out.interface, styleFor(init.io));
            return 0;
        },
        .group_help => |g| {
            try capsule.cli.writeGroupHelp(&out.interface, g, styleFor(init.io));
            return 0;
        },
        .unknown_verb => |u| {
            try err.interface.print("capsule: unknown command '{s} {s}'\n", .{ u.group.name, u.verb });
            try capsule.cli.writeGroupHelp(&err.interface, u.group, styleFor(init.io));
            return 2;
        },
        .command => |c| {
            const tail = if (c.isBare()) argv.items[1..] else argv.items[2..];
            const flags = readFlags(tail);
            var ctx = capsule.cmd.Ctx{
                .arena = arena,
                .io = init.io,
                .settings = settings,
                .socket = paths.socket,
                .environ = init.environ_map,
                .out = &out.interface,
                .err = &err.interface,
                .exe = exe_path,
                .args = flags.args,
                .json = flags.json,
            };
            return capsule.cmd.run(&ctx, c);
        },
    }

    return rawCall(arena, init, paths.socket, command, if (rest.len > 0) rest[0] else "{}", &out.interface, &err.interface);
}

/// The next unread argument, or null. Replaces the argument iterator so the same list can
/// be both consumed positionally and resolved against the command table.
fn take(rest: []const []const u8, taken: *usize) ?[]const u8 {
    if (taken.* >= rest.len) return null;
    defer taken.* += 1;
    return rest[taken.*];
}

/// Help carries colour only when it is going to a terminal, so a piped `capsule help`
/// stays readable.
fn styleFor(io: std.Io) capsule.cli.Style {
    return capsule.cli.Style.forTty(std.Io.File.stdout().isTty(io) catch false);
}

/// `--json` is global rather than per-command: every handler that renders a table can
/// print the daemon's object instead, and a scripted caller should not have to know which.
fn readFlags(args: []const []const u8) struct { args: []const []const u8, json: bool } {
    if (args.len > 0 and std.mem.eql(u8, args[args.len - 1], "--json")) {
        return .{ .args = args[0 .. args.len - 1], .json = true };
    }
    return .{ .args = args, .json = false };
}

/// The escape hatch: a method name sent straight to the daemon. Kept because the
/// integration tests and the agent-side tooling speak the protocol directly.
fn rawCall(
    arena: std.mem.Allocator,
    init: std.process.Init,
    socket: []const u8,
    command: []const u8,
    params: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    const response = capsule.client.call(arena, init.io, socket, command, params) catch |e| switch (e) {
        error.DaemonNotRunning => {
            try err.writeAll("capsule is not running — run 'capsule daemon start'\n");
            return 1;
        },
        else => {
            try err.print("capsule: {t}\n", .{e});
            return 1;
        },
    };

    if (response.ok) {
        try out.print("{s}\n", .{response.body});
        return 0;
    }
    try err.print("capsule: {s}\n", .{response.message orelse response.body});
    if (response.hint) |h| try err.print("  try: {s}\n", .{h});
    return 1;
}

/// The config file layered over the environment, with anything unusable reported.
///
/// An unreadable line is a warning naming its line number, never a refusal: a stray line
/// in a file that worked yesterday should cost one setting, not the whole tool. A value
/// that would change the meaning of a remote command line is the exception — that is
/// refused, exactly as the shell version refused a `CAPSULE_VM_HOST` without an `@`.
/// The board's project context, encoded from the working directory.
///
/// Null outside a repository, which is a perfectly normal way to open the board: it then
/// shows the VM and nothing project-shaped, rather than refusing to start.
fn boardParams(arena: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const repo = capsule.git.discover(arena, io) catch return null;

    var out: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(arena, &out);
    std.json.Stringify.value(.{
        .git_common_dir = repo.git_common_dir,
        .cwd = repo.cwd,
    }, capsule.api.stringify_options, &w.writer) catch return null;
    return w.written();
}

fn loadSettings(
    arena: std.mem.Allocator,
    init: std.process.Init,
    err: *std.Io.Writer,
) !capsule.config.Config {
    const environ = init.environ_map;

    // Resolved too, not just parsed: the derived paths (data dir, control dir) must be
    // filled in on this path as well, or losing the config file would silently hand the
    // ssh layer an empty control directory and a ControlPath of "/cm-%C".
    const fallback = blk: {
        const base = capsule.config.fromEnv(environ);
        break :blk capsule.config.resolve(arena, base, environ) catch base;
    };

    const path = capsule.config.defaultPath(arena, environ) catch return fallback;
    const parsed = capsule.config.load(arena, init.io, path, environ) catch return fallback;

    for (parsed.warnings) |w| {
        err.print("capsule: {s}: line {d}: {s}\n", .{
            path, w.line_no,
            switch (w.kind) {
                .malformed => "not a KEY=value setting — ignored",
                .unknown_key => "unknown setting — ignored",
                .bad_number => "expected a number — ignored",
            },
        }) catch {};
    }

    const resolved = capsule.config.resolve(arena, parsed.config, environ) catch parsed.config;
    if (capsule.config.check(resolved)) |problem| {
        err.print("capsule: {s} {s}\n", .{ problem.key, problem.reason }) catch {};
        return error.BadConfig;
    }
    return resolved;
}

/// A malformed port in the environment falls back rather than refusing to start: the
/// daemon is a background service, and dying on a typo in a config file is the one
/// failure mode nobody would see the reason for.
fn parsePort(text: ?[]const u8, fallback: u16) u16 {
    const t = text orelse return fallback;
    return std.fmt.parseInt(u16, t, 10) catch fallback;
}

/// Empty counts as absent: these arrive from bash, where an unset profile value is an
/// empty word rather than a missing one.
fn orDefault(text: ?[]const u8, fallback: []const u8) []const u8 {
    const t = text orelse return fallback;
    return if (t.len > 0) t else fallback;
}

test {
    _ = capsule;
}
