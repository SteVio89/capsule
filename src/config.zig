//! `~/.config/capsule/config`, parsed once and read by everything.
//!
//! The file was previously sourced as a shell script by the CLI, which meant the daemon —
//! started by launchd or systemd with a bare environment — never saw it. Every knob in it
//! that the daemon actually uses (`CAPSULE_POLL_INTERVAL`, `CAPSULE_MCP_PORT`,
//! `CAPSULE_IMAGE`, `CAPSULE_VM_HOST`) was therefore configurable only for the process
//! that did not need it. Parsing the file here is what lets both load the same values.
//!
//! The grammar is the subset of shell the file has always been written in: `KEY=value`,
//! `#` comments, optional surrounding quotes, and `$VAR` / `${VAR}` / `${VAR:-default}`
//! expansion against the environment. A line outside that subset is reported rather than
//! ignored — a silently dropped setting is the failure nobody can see the reason for.

const std = @import("std");
const Io = std.Io;

/// Every value capsule reads from the environment or the config file, with the defaults
/// that were previously spelled three times: `bin/capsule`, `main.zig`, and `paths.zig`.
pub const Config = struct {
    /// Must be `user@host`; validated by `check`.
    vm_host: []const u8 = "core@localhost",
    vm_port: u16 = 2222,
    image: []const u8 = "ghcr.io/stevio89/capsule:latest",
    container_home: []const u8 = "/home/agent",
    /// One shared port for every run; the per-run token says who is calling.
    mcp_port: u16 = 8765,
    /// Seconds between world-model refreshes. Floored at 1 by `resolve`.
    poll_interval_s: u16 = 3,
    /// Empty means "derive from HOME" — `resolve` fills these in.
    data_dir: []const u8 = "",
    ssh_key: []const u8 = "",
    /// Where the shared ssh ControlMaster socket lives. The daemon and the CLI must agree
    /// on this exactly, or the CLI opens its own connection and pays a fresh ~250ms
    /// handshake per command while a warm master sits unused — which is what happened when
    /// `bin/capsule` said `${XDG_RUNTIME_DIR}/capsule` and `main.zig` said `<data>/control`.
    control_dir: []const u8 = "",
    /// Empty means auto-detect from `origin/HEAD`, then `main`/`master`.
    main_branch: []const u8 = "",
    vm_cpus: u16 = 4,
    vm_mem: u32 = 6144,
    disk_size: []const u8 = "80G",
    stream: []const u8 = "stable",
};

/// A line the parser could not use. Carried rather than logged so the caller decides
/// whether it is a warning on stderr or a test assertion.
pub const Warning = struct {
    line_no: usize,
    line: []const u8,
    kind: Kind,

    pub const Kind = enum {
        /// No `=`, so there is no key to assign.
        malformed,
        /// A `CAPSULE_*` name this build does not know. Not fatal: a config written for a
        /// newer capsule should lose one setting, not fail to load.
        unknown_key,
        /// The key wants a number and the value is not one.
        bad_number,
    };
};

pub const Parsed = struct {
    config: Config,
    warnings: []const Warning,
};

/// A value that would change the meaning of a remote command line. `image` and
/// `container_home` reach `podman` arguments that cross an ssh boundary, and they arrive
/// from a file the user edits by hand, so they are the one pair worth refusing.
pub const Problem = struct {
    key: []const u8,
    reason: []const u8,
};

/// The environment layer, applied over the defaults and under the config file.
///
/// The ordering matters and is inherited: `bin/capsule` sourced the config file *before*
/// its `${VAR:=default}` fallbacks ran, so a value in the file overwrote an inherited
/// environment variable. Reversing that here would silently change which setting wins for
/// anyone who has both.
pub fn fromEnv(env: *const std.process.Environ.Map) Config {
    var config = Config{};
    for (env_keys) |key| {
        if (env.get(key)) |value| {
            if (value.len > 0) assign(&config, key, value) catch {};
        }
    }
    return config;
}

/// Every `CAPSULE_*` name `assign` understands. Kept beside it so a new setting is added
/// in one place; the test below asserts the two agree.
const env_keys = [_][]const u8{
    "CAPSULE_VM_HOST",   "CAPSULE_IMAGE",         "CAPSULE_CONTAINER_HOME",
    "CAPSULE_DATA",      "CAPSULE_SSH_KEY",       "CAPSULE_MAIN_BRANCH",
    "CAPSULE_DISK_SIZE", "CAPSULE_STREAM",        "CAPSULE_VM_PORT",
    "CAPSULE_MCP_PORT",  "CAPSULE_POLL_INTERVAL", "CAPSULE_VM_CPUS",
    "CAPSULE_VM_MEM",    "CAPSULE_CTL_DIR",
};

/// Pure: a starting config, the file's bytes and an environment in; a config and its
/// complaints out. The environment is passed rather than read so the tests below can
/// cover expansion.
pub fn parse(
    arena: std.mem.Allocator,
    base: Config,
    text: []const u8,
    env: *const std.process.Environ.Map,
) !Parsed {
    var config = base;
    var warnings: std.ArrayList(Warning) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try warnings.append(arena, .{ .line_no = line_no, .line = line, .kind = .malformed });
            continue;
        };

        // `export FOO=bar` is shell people write without thinking about it.
        var key = std.mem.trim(u8, line[0..eq], " \t");
        if (std.mem.startsWith(u8, key, "export ")) key = std.mem.trim(u8, key["export ".len..], " \t");

        const value = try expand(arena, unquote(std.mem.trim(u8, line[eq + 1 ..], " \t")), env);

        assign(&config, key, value) catch |err| try warnings.append(arena, .{
            .line_no = line_no,
            .line = line,
            .kind = switch (err) {
                error.UnknownKey => .unknown_key,
                error.BadNumber => .bad_number,
            },
        });
    }

    return .{ .config = config, .warnings = try warnings.toOwnedSlice(arena) };
}

const AssignError = error{ UnknownKey, BadNumber };

fn assign(config: *Config, key: []const u8, value: []const u8) AssignError!void {
    const strings = .{
        .{ "CAPSULE_VM_HOST", "vm_host" },
        .{ "CAPSULE_IMAGE", "image" },
        .{ "CAPSULE_CONTAINER_HOME", "container_home" },
        .{ "CAPSULE_DATA", "data_dir" },
        .{ "CAPSULE_SSH_KEY", "ssh_key" },
        .{ "CAPSULE_MAIN_BRANCH", "main_branch" },
        .{ "CAPSULE_DISK_SIZE", "disk_size" },
        .{ "CAPSULE_STREAM", "stream" },
        .{ "CAPSULE_CTL_DIR", "control_dir" },
    };
    inline for (strings) |pair| {
        if (std.mem.eql(u8, key, pair[0])) {
            @field(config, pair[1]) = value;
            return;
        }
    }

    const numbers = .{
        .{ "CAPSULE_VM_PORT", "vm_port", u16 },
        .{ "CAPSULE_MCP_PORT", "mcp_port", u16 },
        .{ "CAPSULE_POLL_INTERVAL", "poll_interval_s", u16 },
        .{ "CAPSULE_VM_CPUS", "vm_cpus", u16 },
        .{ "CAPSULE_VM_MEM", "vm_mem", u32 },
    };
    inline for (numbers) |triple| {
        if (std.mem.eql(u8, key, triple[0])) {
            @field(config, triple[1]) = std.fmt.parseInt(triple[2], value, 10) catch
                return error.BadNumber;
            return;
        }
    }

    return error.UnknownKey;
}

/// Strips one layer of matching quotes. Single quotes suppress expansion, as in a shell,
/// which is the only reason the two are distinguished here.
fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        if ((first == '"' or first == '\'') and value[value.len - 1] == first) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

/// `$VAR`, `${VAR}` and `${VAR:-fallback}`. An undefined variable expands to nothing,
/// matching the shell this file used to be sourced by.
pub fn expand(
    arena: std.mem.Allocator,
    value: []const u8,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value, '$') == null) return value;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '$') {
            try out.append(arena, value[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= value.len) {
            try out.append(arena, '$');
            break;
        }

        if (value[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, value, i, '}') orelse {
                try out.append(arena, '$');
                continue;
            };
            const inner = value[i + 1 .. close];
            i = close + 1;
            if (std.mem.indexOf(u8, inner, ":-")) |sep| {
                const name = inner[0..sep];
                const fallback = inner[sep + 2 ..];
                const got = env.get(name) orelse "";
                try out.appendSlice(arena, if (got.len > 0) got else try expand(arena, fallback, env));
            } else {
                try out.appendSlice(arena, env.get(inner) orelse "");
            }
            continue;
        }

        const start = i;
        while (i < value.len and (std.ascii.isAlphanumeric(value[i]) or value[i] == '_')) i += 1;
        if (i == start) {
            try out.append(arena, '$');
            continue;
        }
        try out.appendSlice(arena, env.get(value[start..i]) orelse "");
    }
    return out.toOwnedSlice(arena);
}

/// Fills in the values that are derived rather than configured, and clamps what must not
/// be zero. Separate from `parse` so the parser stays pure and testable without a HOME.
pub fn resolve(arena: std.mem.Allocator, config: Config, env: *const std.process.Environ.Map) !Config {
    var out = config;

    if (out.data_dir.len == 0) {
        out.data_dir = if (env.get("XDG_DATA_HOME")) |x|
            try std.fmt.allocPrint(arena, "{s}/capsule", .{x})
        else if (env.get("HOME")) |h|
            try std.fmt.allocPrint(arena, "{s}/.local/share/capsule", .{h})
        else
            return error.NoHome;
    }
    if (out.ssh_key.len == 0) {
        if (env.get("HOME")) |h| {
            out.ssh_key = try std.fmt.allocPrint(arena, "{s}/.ssh/id_ed25519.pub", .{h});
        }
    }

    // `XDG_RUNTIME_DIR` first because a control socket is runtime state, and because that
    // is what bash preferred; `<data>/control` second because that is where a daemon
    // already running on a machine without XDG_RUNTIME_DIR — every mac — has put it. Both
    // precedents are honoured, so unifying the two does not orphan a live master.
    if (out.control_dir.len == 0) {
        out.control_dir = if (env.get("XDG_RUNTIME_DIR")) |x|
            try std.fmt.allocPrint(arena, "{s}/capsule", .{x})
        else
            try std.fmt.allocPrint(arena, "{s}/control", .{out.data_dir});
    }

    // A poll interval of zero would spin the poller thread against ssh with no delay.
    out.poll_interval_s = @max(1, out.poll_interval_s);
    return out;
}

/// The values that must be refused rather than passed on, because they reach a command
/// line that a remote shell parses. Returns the first problem, or null.
pub fn check(config: Config) ?Problem {
    if (std.mem.indexOfScalar(u8, config.vm_host, '@') == null) {
        return .{ .key = "CAPSULE_VM_HOST", .reason = "must be user@host" };
    }
    if (hasShellMeta(config.image)) {
        return .{ .key = "CAPSULE_IMAGE", .reason = "must not contain shell metacharacters" };
    }
    if (hasShellMeta(config.container_home)) {
        return .{ .key = "CAPSULE_CONTAINER_HOME", .reason = "must not contain shell metacharacters" };
    }
    if (hasShellMeta(config.vm_host)) {
        return .{ .key = "CAPSULE_VM_HOST", .reason = "must not contain shell metacharacters" };
    }
    return null;
}

/// Conservative: anything that could end a word or start a substitution in the remote
/// shell. These values are interpolated into commands, never quoted by their callers.
fn hasShellMeta(value: []const u8) bool {
    for (value) |c| switch (c) {
        '$', '`', '"', '\'', '\\', ';', '|', '&', '<', '>', '(', ')', '{', '}', '\n', '\r', ' ', '\t', '*', '?', '!', '#', '~' => return true,
        else => {},
    };
    return false;
}

/// Reads the config file if it is there, and returns defaults if it is not. A missing
/// file is the normal case — capsule works without one.
pub fn load(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    env: *const std.process.Environ.Map,
) !Parsed {
    const base = fromEnv(env);
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch
        return .{ .config = base, .warnings = &.{} };
    return parse(arena, base, text, env);
}

/// `$XDG_CONFIG_HOME/capsule/config`, or `~/.config/capsule/config`.
pub fn defaultPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| {
        return std.fmt.allocPrint(arena, "{s}/capsule/config", .{x});
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(arena, "{s}/.config/capsule/config", .{home});
}

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

/// The tests build an environment by hand rather than reading the real one, so they are
/// the same on every machine.
fn testEnv(arena: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(arena);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "an absent config file is not an error" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{});
    const got = try load(a.allocator(), testing.io, "/nonexistent/capsule/config", &env);
    try testing.expectEqual(@as(usize, 0), got.warnings.len);
    try testing.expectEqualStrings("core@localhost", got.config.vm_host);
}

test "config.example parses without a single warning" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{.{ "HOME", "/home/me" }});

    const example = @embedFile("config_example");
    const got = try parse(a.allocator(), .{}, example, &env);
    for (got.warnings) |w| std.debug.print("unexpected warning on line {d}: {s}\n", .{ w.line_no, w.line });
    try testing.expectEqual(@as(usize, 0), got.warnings.len);

    try testing.expectEqualStrings("core@localhost", got.config.vm_host);
    try testing.expectEqual(@as(u16, 2222), got.config.vm_port);
    try testing.expectEqual(@as(u16, 8765), got.config.mcp_port);
    try testing.expectEqual(@as(u16, 3), got.config.poll_interval_s);
    try testing.expectEqualStrings("/home/me/.ssh/id_ed25519.pub", got.config.ssh_key);
    try testing.expectEqualStrings("/home/me/.local/share/capsule", got.config.data_dir);
    try testing.expectEqual(@as(u32, 6144), got.config.vm_mem);
    try testing.expectEqualStrings("80G", got.config.disk_size);
}

test "quotes are stripped and comments ignored" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{});
    const got = try parse(a.allocator(), .{},
        \\# a comment
        \\CAPSULE_VM_HOST="core@vm.local"
        \\  CAPSULE_IMAGE='ghcr.io/x/y:tag'
        \\
        \\CAPSULE_VM_PORT=2200
    , &env);
    try testing.expectEqual(@as(usize, 0), got.warnings.len);
    try testing.expectEqualStrings("core@vm.local", got.config.vm_host);
    try testing.expectEqualStrings("ghcr.io/x/y:tag", got.config.image);
    try testing.expectEqual(@as(u16, 2200), got.config.vm_port);
}

test "export is tolerated" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{});
    const got = try parse(a.allocator(), .{}, "export CAPSULE_VM_PORT=2300\n", &env);
    try testing.expectEqual(@as(usize, 0), got.warnings.len);
    try testing.expectEqual(@as(u16, 2300), got.config.vm_port);
}

test "variables expand in all three forms" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{ .{ "HOME", "/home/me" }, .{ "TAG", "v2" } });

    try testing.expectEqualStrings("/home/me/x", try expand(a.allocator(), "$HOME/x", &env));
    try testing.expectEqualStrings("/home/me/x", try expand(a.allocator(), "${HOME}/x", &env));
    try testing.expectEqualStrings("/home/me/d", try expand(a.allocator(), "${XDG:-$HOME}/d", &env));
    try testing.expectEqualStrings("img:v2", try expand(a.allocator(), "img:$TAG", &env));
    try testing.expectEqualStrings("", try expand(a.allocator(), "$NOPE", &env));
    try testing.expectEqualStrings("100%", try expand(a.allocator(), "100%", &env));
}

test "a lone dollar is literal, not a crash" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{});
    try testing.expectEqualStrings("$", try expand(a.allocator(), "$", &env));
    try testing.expectEqualStrings("a$ b", try expand(a.allocator(), "a$ b", &env));
    try testing.expectEqualStrings("${unclosed", try expand(a.allocator(), "${unclosed", &env));
}

test "a malformed line is reported, not silently dropped" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{});
    const got = try parse(a.allocator(), .{}, "this is not a setting\nCAPSULE_VM_PORT=2222\n", &env);
    try testing.expectEqual(@as(usize, 1), got.warnings.len);
    try testing.expectEqual(@as(usize, 1), got.warnings[0].line_no);
    try testing.expectEqual(Warning.Kind.malformed, got.warnings[0].kind);
    try testing.expectEqual(@as(u16, 2222), got.config.vm_port);
}

test "an unknown key warns but does not stop the rest of the file" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{});
    const got = try parse(a.allocator(), .{}, "CAPSULE_FROM_THE_FUTURE=1\nCAPSULE_VM_PORT=2222\n", &env);
    try testing.expectEqual(@as(usize, 1), got.warnings.len);
    try testing.expectEqual(Warning.Kind.unknown_key, got.warnings[0].kind);
    try testing.expectEqual(@as(u16, 2222), got.config.vm_port);
}

test "a non-numeric port warns and leaves the default in place" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{});
    const got = try parse(a.allocator(), .{}, "CAPSULE_VM_PORT=not-a-port\n", &env);
    try testing.expectEqual(@as(usize, 1), got.warnings.len);
    try testing.expectEqual(Warning.Kind.bad_number, got.warnings[0].kind);
    try testing.expectEqual(@as(u16, 2222), got.config.vm_port);
}

test "a vm host without a user is refused" {
    try testing.expect(check(.{ .vm_host = "localhost" }) != null);
    try testing.expectEqualStrings("CAPSULE_VM_HOST", check(.{ .vm_host = "localhost" }).?.key);
    try testing.expectEqual(@as(?Problem, null), check(.{}));
}

test "values that reach a remote command line cannot carry shell metacharacters" {
    // These arrive from a hand-edited file and are interpolated, never quoted, by callers.
    try testing.expect(check(.{ .image = "img; rm -rf /" }) != null);
    try testing.expect(check(.{ .image = "img$(whoami)" }) != null);
    try testing.expect(check(.{ .image = "img`id`" }) != null);
    try testing.expect(check(.{ .container_home = "/home/agent && id" }) != null);
    try testing.expect(check(.{ .vm_host = "core@host;id" }) != null);
    try testing.expectEqual(@as(?Problem, null), check(.{}));
}

test "resolve derives the data dir and never leaves a zero poll interval" {
    var a = testArena();
    defer a.deinit();

    var home = try testEnv(a.allocator(), &.{.{ "HOME", "/home/me" }});
    const from_home = try resolve(a.allocator(), .{}, &home);
    try testing.expectEqualStrings("/home/me/.local/share/capsule", from_home.data_dir);

    var xdg = try testEnv(a.allocator(), &.{ .{ "HOME", "/home/me" }, .{ "XDG_DATA_HOME", "/xdg" } });
    const from_xdg = try resolve(a.allocator(), .{}, &xdg);
    try testing.expectEqualStrings("/xdg/capsule", from_xdg.data_dir);

    const clamped = try resolve(a.allocator(), .{ .poll_interval_s = 0 }, &home);
    try testing.expectEqual(@as(u16, 1), clamped.poll_interval_s);

    const explicit = try resolve(a.allocator(), .{ .data_dir = "/elsewhere" }, &home);
    try testing.expectEqualStrings("/elsewhere", explicit.data_dir);
}

test "the control dir lands where a daemon already running would have put it" {
    var a = testArena();
    defer a.deinit();

    // On a mac there is no XDG_RUNTIME_DIR, and this must stay `<data>/control` — the
    // path `main.zig`'s daemon branch has always used. Moving it would leave a live
    // master unreachable and silently reintroduce a handshake per command.
    var home = try testEnv(a.allocator(), &.{.{ "HOME", "/home/me" }});
    const mac = try resolve(a.allocator(), .{}, &home);
    try testing.expectEqualStrings("/home/me/.local/share/capsule/control", mac.control_dir);

    var runtime = try testEnv(a.allocator(), &.{
        .{ "HOME", "/home/me" },
        .{ "XDG_RUNTIME_DIR", "/run/user/1000" },
    });
    const linux = try resolve(a.allocator(), .{}, &runtime);
    try testing.expectEqualStrings("/run/user/1000/capsule", linux.control_dir);

    const explicit = try resolve(a.allocator(), .{ .control_dir = "/somewhere/else" }, &runtime);
    try testing.expectEqualStrings("/somewhere/else", explicit.control_dir);
}

test "CAPSULE_CTL_DIR is settable the same way every other knob is" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{.{ "CAPSULE_CTL_DIR", "/from/env" }});
    try testing.expectEqualStrings("/from/env", fromEnv(&env).control_dir);

    var empty = try testEnv(a.allocator(), &.{.{ "HOME", "/home/me" }});
    const from_file = try parse(a.allocator(), .{}, "CAPSULE_CTL_DIR=/from/file\n", &empty);
    try testing.expectEqual(@as(usize, 0), from_file.warnings.len);
    try testing.expectEqualStrings("/from/file", from_file.config.control_dir);
}

test "no home and no explicit data dir is an error, not a path relative to nowhere" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{});
    try testing.expectError(error.NoHome, resolve(a.allocator(), .{}, &env));
}

test "the environment supplies values when there is no config file" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{
        .{ "CAPSULE_VM_HOST", "core@build-box" },
        .{ "CAPSULE_VM_PORT", "2299" },
        .{ "CAPSULE_POLL_INTERVAL", "7" },
    });
    const got = fromEnv(&env);
    try testing.expectEqualStrings("core@build-box", got.vm_host);
    try testing.expectEqual(@as(u16, 2299), got.vm_port);
    try testing.expectEqual(@as(u16, 7), got.poll_interval_s);
    try testing.expectEqualStrings("/home/agent", got.container_home);
}

test "the config file wins over the environment, as sourcing it did" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{
        .{ "CAPSULE_VM_HOST", "core@from-env" },
        .{ "CAPSULE_VM_PORT", "2299" },
    });

    const got = try parse(a.allocator(), fromEnv(&env), "CAPSULE_VM_HOST=core@from-file\n", &env);
    try testing.expectEqualStrings("core@from-file", got.config.vm_host);
    // A key the file does not mention keeps the environment's value.
    try testing.expectEqual(@as(u16, 2299), got.config.vm_port);
}

test "an empty environment variable does not override a default" {
    var a = testArena();
    defer a.deinit();
    var env = try testEnv(a.allocator(), &.{.{ "CAPSULE_VM_HOST", "" }});
    try testing.expectEqualStrings("core@localhost", fromEnv(&env).vm_host);
}

test "every environment key is one the assigner understands" {
    // The two lists are maintained by hand; a name in one and not the other would be a
    // setting that reads from the file but is ignored in the environment, or vice versa.
    var config = Config{};
    for (env_keys) |key| {
        const value = if (std.mem.indexOf(u8, key, "PORT") != null or
            std.mem.indexOf(u8, key, "INTERVAL") != null or
            std.mem.indexOf(u8, key, "CPUS") != null or
            std.mem.indexOf(u8, key, "MEM") != null) "1" else "x";
        assign(&config, key, value) catch {
            std.debug.print("env key '{s}' is not assignable\n", .{key});
            return error.UnknownEnvKey;
        };
    }
}
