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
//!
//! There is deliberately no "draws on the terminal, output is data" shape. `run review`
//! wanted one and it does not work: a TUI handed a pipe for stdout cannot initialise its
//! input source, so the program starts and then refuses every keystroke. A program that
//! takes the screen gets all three descriptors, and its output is read back some other way.

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
    const tty = openTty(io);
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

/// `/dev/tty`, in **blocking** mode, or null when there is no controlling terminal.
///
/// The second part is the whole reason this exists. `Io.Threaded` opens every file with
/// `O_NONBLOCK`, and `SpawnOptions.StdIo.file` keeps that mode in the child — the stdlib
/// says so and warns that children generally do not support it. A child that reads a
/// non-blocking stdin gets `EAGAIN`, and `ssh` takes that for end of input: `capsule vm
/// ssh` opened a session and closed it in the same instant, every time.
///
/// `vim` hid this for a while, because an editor opens `/dev/tty` for itself rather than
/// trusting the descriptor it was handed.
fn openTty(io: Io) ?Io.File {
    const tty = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch return null;

    // `O` is a packed struct rather than a set of constants, so the bit is derived from
    // the struct itself instead of hardcoding a value that differs per platform.
    const nonblock: c_int = @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));

    const flags = std.c.fcntl(tty.handle, std.c.F.GETFL, @as(c_int, 0));
    if (flags >= 0) _ = std.c.fcntl(tty.handle, std.c.F.SETFL, flags & ~nonblock);
    return tty;
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
