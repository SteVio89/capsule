//! capsuled: one binary, three roles — daemon, MCP endpoint, dashboard client.

const std = @import("std");
const capsuled = @import("capsuled");

/// A panic while the board holds the terminal in raw mode on the alternate screen would
/// otherwise leave the user's shell unusable and the panic message invisible. Restore
/// first, then let the default panic do its work where it can be read.
pub const panic = std.debug.FullPanic(panicWithTerminalRestored);

fn panicWithTerminalRestored(msg: []const u8, first_trace_addr: ?usize) noreturn {
    capsuled.tui.term.emergencyRestore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

const usage =
    \\usage: capsuled <command> [params-json]
    \\
    \\  daemon              run the host daemon: store, world model, MCP endpoint
    \\  version             print the version and exit
    \\
    \\Anything else is sent to the daemon as a method name, with the optional second
    \\argument passed through as its params object. The response's `result` is printed
    \\on stdout; an error prints its message on stderr and exits 1.
    \\
    \\  capsuled ping
    \\  capsuled daemon.status
    \\
;

/// Dispatches on argv[1] and returns the process exit code, which bash branches on.
pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    defer out.interface.flush() catch {};

    var err_buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    defer err.interface.flush() catch {};

    var args = init.minimal.args.iterate();
    _ = args.next();
    const command = args.next() orelse {
        try out.interface.writeAll(usage);
        return 2;
    };

    if (std.mem.eql(u8, command, "version")) {
        try out.interface.writeAll("capsuled 0.1.0\n");
        return 0;
    }

    const paths = capsuled.paths.resolve(arena, .{
        .home = init.environ_map.get("HOME"),
        .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
        .capsule_socket = init.environ_map.get("CAPSULE_SOCKET"),
        .capsule_db = init.environ_map.get("CAPSULE_DB"),
    }) catch |e| {
        try err.interface.print("capsuled: {t}\n", .{e});
        return 1;
    };

    if (std.mem.eql(u8, command, "daemon")) {
        std.Io.Dir.cwd().createDirPath(init.io, paths.data_dir) catch {};

        const ctl_dir = init.environ_map.get("CAPSULE_CTL_DIR") orelse
            try std.fmt.allocPrint(arena, "{s}/control", .{paths.data_dir});
        std.Io.Dir.cwd().createDirPath(init.io, ctl_dir) catch {};

        var d = capsuled.daemon.Daemon.init(init.gpa, init.io, .{
            .socket_path = paths.socket,
            .db_path = try arena.dupeZ(u8, paths.db),
            .ssh = .{
                .vm_host = init.environ_map.get("CAPSULE_VM_HOST") orelse "core@localhost",
                .vm_port = parsePort(init.environ_map.get("CAPSULE_VM_PORT"), 2222),
                .control_dir = ctl_dir,
                .mcp_port = parsePort(init.environ_map.get("CAPSULE_MCP_PORT"), 8765),
                .image = init.environ_map.get("CAPSULE_IMAGE") orelse "",
            },
            .poll_interval_s = @max(1, parsePort(init.environ_map.get("CAPSULE_POLL_INTERVAL"), 3)),
        }) catch |e| {
            try err.interface.print("capsuled: cannot open {s}: {t}\n", .{ paths.db, e });
            return 1;
        };
        defer d.deinit();

        d.serve() catch |e| switch (e) {
            error.AlreadyRunning => {
                try err.interface.print(
                    "capsuled: already running on {s}\n",
                    .{paths.socket},
                );
                return 1;
            },
            else => {
                try err.interface.print("capsuled: {t}\n", .{e});
                return 1;
            },
        };
        return 0;
    }

    if (std.mem.eql(u8, command, "edit")) {
        const seed = args.next() orelse "";
        const header = args.next() orelse "";
        const seeded = if (header.len > 0)
            try std.fmt.allocPrint(arena, "{s}\n{s}", .{ header, seed })
        else
            seed;

        const tmp = init.environ_map.get("TMPDIR") orelse
            init.environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
        const result = capsuled.editor.editText(arena, init.io, init.environ_map, seeded, tmp) catch |e| {
            try err.interface.print("capsuled: editor failed: {t}\n", .{e});
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
        const dir = args.next() orelse {
            try err.interface.writeAll(
                "usage: capsuled seed <dir> <issue> <title> <project-dir> [port] [theme] [editor-mode]\n",
            );
            return 2;
        };
        const issue_short = args.next() orelse "";
        const title = args.next() orelse "";
        const project_dir = args.next() orelse "";
        const port = parsePort(args.next(), 8765);
        const theme = orDefault(args.next(), "dark");
        const editor_mode = orDefault(args.next(), "vim");

        const template_path = try std.fmt.allocPrint(
            arena,
            "{s}/capsule/agent-settings.json",
            .{init.environ_map.get("XDG_CONFIG_HOME") orelse
                try std.fmt.allocPrint(arena, "{s}/.config", .{init.environ_map.get("HOME") orelse "/root"})},
        );
        const template = std.Io.Dir.cwd().readFileAlloc(init.io, template_path, arena, .limited(1 << 20)) catch "";

        capsuled.seed.writeTree(arena, init.io, dir, template, .{
            .issue_short = issue_short,
            .issue_title = title,
            .project_dir = project_dir,
            .mcp_port = port,
            .theme = theme,
            .editor_mode = editor_mode,
        }) catch |e| {
            try err.interface.print("capsuled: cannot seed {s}: {t}\n", .{ dir, e });
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, command, "container-cmd") or std.mem.eql(u8, command, "attach-cmd")) {
        const is_attach = std.mem.eql(u8, command, "attach-cmd");
        const name = args.next() orelse return 2;

        const argv = if (is_attach)
            try capsuled.run.attachArgs(arena, name)
        else
            try capsuled.run.podmanArgs(arena, .{
                .image = init.environ_map.get("CAPSULE_IMAGE") orelse "",
                .container_home = init.environ_map.get("CAPSULE_CONTAINER_HOME") orelse "/home/agent",
                .mcp_port = parsePort(init.environ_map.get("CAPSULE_MCP_PORT"), 8765),
                .container_name = name,
                .project_dir = args.next() orelse "",
                .agent_state_dir = args.next() orelse "",
                .env_file = args.next() orelse "",
                .profile = args.next() orelse "default",
                .issue_short = args.next() orelse "",
            });

        try out.interface.print("{s}\n", .{try capsuled.run.commandLine(arena, argv)});
        return 0;
    }

    if (std.mem.eql(u8, command, "board")) {
        const project_params = args.next() orelse "";
        capsuled.board.run(arena, init.gpa, init.io, paths.socket, project_params) catch |e| switch (e) {
            error.DaemonNotRunning => {
                try err.interface.writeAll("capsuled is not running — run 'capsule daemon start'\n");
                return 1;
            },
            error.NotATerminal => {
                try err.interface.writeAll(
                    "capsule board needs a terminal. For something scriptable, use the CLI:\n" ++
                        "  capsuled world.get\n",
                );
                return 1;
            },
            else => {
                try err.interface.print("capsuled: {t}\n", .{e});
                return 1;
            },
        };
        return 0;
    }

    const params = args.next() orelse "{}";
    const response = capsuled.client.call(arena, init.io, paths.socket, command, params) catch |e| switch (e) {
        error.DaemonNotRunning => {
            try err.interface.writeAll("capsuled is not running — run 'capsule daemon start'\n");
            return 1;
        },
        else => {
            try err.interface.print("capsuled: {t}\n", .{e});
            return 1;
        },
    };

    if (response.ok) {
        try out.interface.print("{s}\n", .{response.body});
        return 0;
    }
    try err.interface.print("capsuled: {s}\n", .{response.message orelse response.body});
    if (response.hint) |h| try err.interface.print("  try: {s}\n", .{h});
    return 1;
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
    _ = capsuled;
}
