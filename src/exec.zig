//! Running other programs, in the three shapes capsule actually needs.
//!
//! The bash CLI spawned processes five different ways and quoted its arguments by hand
//! each time. Everything here takes an **argv slice**, never a command string, so there is
//! no shell to quote for. The one place a shell string is legitimate is the command sent
//! over ssh, which the remote login shell parses — that goes through `ssh.shellQuote`, and
//! it is the only exception.
//!
//! The shapes differ only in where the child's stdio goes, and that difference is the
//! whole reason they are separate functions:
//!
//!   - `run`          — capture both streams. For anything whose output is data.
//!   - `stream`       — inherit the terminal. For output the user should watch scroll by.
//!   - `interactive`  — hand over `/dev/tty`. For programs that take over the screen.
//!   - `runWithInput` — feed the child a file on stdin. For shipping bytes to the VM.
//!   - `interactiveCapture` — both at once: draws on the terminal, output is data.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    /// The program could not be started at all: not on PATH, not executable, no such file.
    SpawnFailed,
    /// The child was killed by a signal or stopped rather than exiting normally.
    Signalled,
    /// `capture` only: the child exited non-zero.
    ExitFailure,
} || std.mem.Allocator.Error;

pub const Options = struct {
    /// Inherited from capsule's own working directory when null.
    cwd: ?[]const u8 = null,
    /// Replaces the child's environment entirely when set.
    environ: ?*const std.process.Environ.Map = null,
    /// Wall-clock cap. `.none` waits forever, which is right for anything the user is
    /// watching and wrong for anything on a poll loop.
    timeout: Io.Timeout = .none,
    stdout_limit: Io.Limit = .unlimited,
    stderr_limit: Io.Limit = .unlimited,
};

pub const Output = struct {
    /// Zero when the child exited normally. A signalled child never reaches here.
    code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn ok(self: Output) bool {
        return self.code == 0;
    }

    /// stdout with one trailing newline removed — what a shell's `$(...)` yields.
    pub fn trimmed(self: Output) []const u8 {
        return std.mem.trimEnd(u8, self.stdout, "\n");
    }

    /// The same for stderr, which is what a failed child's message goes into.
    pub fn trimmedErr(self: Output) []const u8 {
        return std.mem.trimEnd(u8, self.stderr, "\n");
    }

    pub fn deinit(self: Output, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Runs to completion and captures both streams. The caller owns `stdout` and `stderr`.
///
/// A non-zero exit is a normal return, not an error: callers routinely branch on the code
/// (`git rev-parse` failing means "not a repository", not "something broke").
pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    options: Options,
) Error!Output {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = options.environ,
        .timeout = options.timeout,
        .stdout_limit = options.stdout_limit,
        .stderr_limit = options.stderr_limit,
    }) catch return error.SpawnFailed;

    return switch (result.term) {
        .exited => |code| .{ .code = code, .stdout = result.stdout, .stderr = result.stderr },
        else => {
            gpa.free(result.stdout);
            gpa.free(result.stderr);
            return error.Signalled;
        },
    };
}

/// `run`, but a non-zero exit is an error and only trimmed stdout comes back. This is the
/// shape almost every `git` call wants, and it is allocated in `arena` so callers are not
/// threading `defer` through every step of a multi-command sequence.
pub fn capture(
    arena: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    options: Options,
) Error![]const u8 {
    const out = try run(arena, io, argv, options);
    if (out.code != 0) return error.ExitFailure;
    return out.trimmed();
}

/// Runs with capsule's own stdio, so the child writes straight to the user's terminal.
/// Returns the exit code; the caller decides whether it matters.
pub fn stream(io: Io, argv: []const []const u8, options: Options) Error!u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = options.environ,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.SpawnFailed;

    const term = child.wait(io) catch return error.SpawnFailed;
    return switch (term) {
        .exited => |code| code,
        else => error.Signalled,
    };
}

/// Hands the terminal to a program that takes over the screen — the editor, `tuicr`, the
/// picker, `ssh -t`, `qemu -nographic`.
///
/// `/dev/tty` is opened explicitly rather than inheriting, because capsule's own stdout is
/// frequently a pipe: the CLI is run from command substitution, and the board redirects
/// while it holds the alternate screen. Inheriting there would hand the child a pipe and
/// it would refuse to draw. Falls back to inheriting when there is no controlling
/// terminal, which is what makes this safe to call from a script.
pub fn interactive(io: Io, argv: []const []const u8, options: Options) Error!u8 {
    const tty: ?Io.File = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch null;
    defer if (tty) |t| t.close(io);

    const stdio: std.process.SpawnOptions.StdIo = if (tty) |t| .{ .file = t } else .inherit;

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = options.environ,
        .stdin = stdio,
        .stdout = stdio,
        .stderr = stdio,
    }) catch return error.SpawnFailed;

    const term = child.wait(io) catch return error.SpawnFailed;
    return switch (term) {
        .exited => |code| code,
        else => error.Signalled,
    };
}

/// Runs with `input` on the child's stdin and captures stdout, letting stderr through to
/// the terminal. The fourth shape, for the one thing the other three cannot do: hand a
/// child a stream of bytes.
///
/// stdin is an already-open file rather than a buffer, and that is the point. With a pipe
/// the parent blocks once the OS buffer fills, while the child may itself be blocked
/// writing stdout that nobody is draining — a deadlock whose trigger is the size of the
/// payload. A file couples the two not at all.
///
/// stderr is inherited rather than captured so `ssh`'s own diagnostics reach the user as
/// they happen; a batched remote script can take a while, and swallowing its complaints
/// until it finishes is how a hang becomes unexplainable.
pub fn runWithInput(
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    input: Io.File,
    options: Options,
) Error!Output {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = options.environ,
        .stdin = .{ .file = input },
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch return error.SpawnFailed;
    defer child.kill(io);

    var buf: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    const stdout = reader.interface.allocRemaining(gpa, options.stdout_limit) catch
        return error.SpawnFailed;
    errdefer gpa.free(stdout);

    const term = child.wait(io) catch return error.SpawnFailed;
    return switch (term) {
        .exited => |code| .{ .code = code, .stdout = stdout, .stderr = &.{} },
        else => {
            gpa.free(stdout);
            return error.Signalled;
        },
    };
}

/// Hands the terminal to a program that draws on it, while capturing what it writes to
/// stdout. `tuicr` is the case: it reviews a diff on the screen and prints the comments it
/// exported, and both have to happen at once.
///
/// stdin and stderr go to `/dev/tty` for the same reason `interactive` opens it — capsule's
/// own stdio is frequently a pipe — while stdout is a pipe this side drains. Draining as
/// the child runs rather than after it exits is what keeps a large export from filling the
/// pipe buffer and stalling both processes.
pub fn interactiveCapture(
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    options: Options,
) Error!Output {
    const tty: ?Io.File = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch null;
    defer if (tty) |t| t.close(io);

    const stdio: std.process.SpawnOptions.StdIo = if (tty) |t| .{ .file = t } else .inherit;

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = options.environ,
        .stdin = stdio,
        .stdout = .pipe,
        .stderr = stdio,
    }) catch return error.SpawnFailed;
    defer child.kill(io);

    var buf: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    const stdout = reader.interface.allocRemaining(gpa, options.stdout_limit) catch
        return error.SpawnFailed;
    errdefer gpa.free(stdout);

    const term = child.wait(io) catch return error.SpawnFailed;
    return switch (term) {
        .exited => |code| .{ .code = code, .stdout = stdout, .stderr = &.{} },
        else => {
            gpa.free(stdout);
            return error.Signalled;
        },
    };
}

/// Whether a program is on `PATH`. Used for the optional dependencies capsule degrades
/// without — `tuicr` falls back to `git log -p`, and the picker to a plain prompt.
pub fn present(gpa: std.mem.Allocator, io: Io, program: []const u8) bool {
    const out = run(gpa, io, &.{ "command", "-v", program }, .{}) catch {
        // `command` is a shell builtin, so fall back to asking a shell.
        const shell = run(gpa, io, &.{ "sh", "-c", "command -v \"$1\"", "sh", program }, .{}) catch
            return false;
        defer shell.deinit(gpa);
        return shell.ok();
    };
    defer out.deinit(gpa);
    return out.ok();
}

const testing = std.testing;

test "a successful command returns its output and a zero code" {
    const out = try run(testing.allocator, testing.io, &.{ "/bin/echo", "hello" }, .{});
    defer out.deinit(testing.allocator);
    try testing.expect(out.ok());
    try testing.expectEqualStrings("hello\n", out.stdout);
    try testing.expectEqualStrings("hello", out.trimmed());
    try testing.expectEqualStrings("", out.stderr);
}

test "a non-zero exit is reported, not raised" {
    const out = try run(testing.allocator, testing.io, &.{ "/bin/sh", "-c", "exit 3" }, .{});
    defer out.deinit(testing.allocator);
    try testing.expect(!out.ok());
    try testing.expectEqual(@as(u8, 3), out.code);
}

test "the two streams are kept apart" {
    const out = try run(testing.allocator, testing.io, &.{
        "/bin/sh", "-c", "printf out; printf err >&2",
    }, .{});
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("out", out.stdout);
    try testing.expectEqualStrings("err", out.stderr);
}

test "an argument is never word-split, however it is spelled" {
    // The whole reason this module takes argv slices: a bash port that built command
    // strings would split this into three arguments and quietly do something else.
    const out = try run(testing.allocator, testing.io, &.{
        "/bin/echo", "one two three; rm -rf /",
    }, .{});
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("one two three; rm -rf /\n", out.stdout);
}

test "a missing program is an error, not a crash" {
    try testing.expectError(
        error.SpawnFailed,
        run(testing.allocator, testing.io, &.{"/nonexistent/program"}, .{}),
    );
}

test "capture returns trimmed stdout and refuses a failed command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const got = try capture(arena.allocator(), testing.io, &.{ "/bin/echo", "value" }, .{});
    try testing.expectEqualStrings("value", got);

    try testing.expectError(error.ExitFailure, capture(
        arena.allocator(),
        testing.io,
        &.{ "/bin/sh", "-c", "exit 1" },
        .{},
    ));
}

test "cwd is honoured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try capture(arena.allocator(), testing.io, &.{"/bin/pwd"}, .{ .cwd = "/tmp" });
    // macOS reports /tmp as a symlink to /private/tmp, so match the tail rather than all.
    try testing.expect(std.mem.endsWith(u8, got, "/tmp"));
}

test "a signalled child is distinguished from a non-zero exit" {
    try testing.expectError(error.Signalled, run(
        testing.allocator,
        testing.io,
        &.{ "/bin/sh", "-c", "kill -TERM $$" },
        .{},
    ));
}

test "stream returns the child's exit code" {
    // stdio is inherited, so this writes nothing the test runner would show.
    try testing.expectEqual(@as(u8, 0), try stream(testing.io, &.{ "/bin/sh", "-c", "exit 0" }, .{}));
    try testing.expectEqual(@as(u8, 7), try stream(testing.io, &.{ "/bin/sh", "-c", "exit 7" }, .{}));
}

test "presence of a program is answered without throwing" {
    try testing.expect(present(testing.allocator, testing.io, "sh"));
    try testing.expect(!present(testing.allocator, testing.io, "definitely-not-a-real-program-xyz"));
}
