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
//! There is no "draws on the terminal, output is data" shape, but not for the reason the
//! commit that deleted one gave. It claimed a TUI handed a pipe for stdout cannot start its
//! input source; the shell CLI ran `tuicr` inside command substitution — stdout on a pipe —
//! for its whole life, and that worked. What both Zig ports changed was the *other* two
//! descriptors, from inherited to a `/dev/tty` capsule opens itself, and that is what
//! `Options.terminal` selects.
//!
//! `interactive` is also the only shape that has to survive its child misbehaving, because
//! it is the only one that lends out the terminal. It returns an `Exit` rather than a bare
//! code, puts the terminal back the way it found it, and waits in a way that can see a
//! *stopped* child — see `Exit` for why the stdlib's own wait cannot.

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

/// Which descriptors a terminal handover gives the child. Read only by `interactive`.
pub const Terminal = enum {
    /// A `/dev/tty` capsule opens for itself. The right default: the CLI is routinely run
    /// from command substitution, so capsule's own stdout is frequently a pipe, and a child
    /// handed that would refuse to draw.
    own,
    /// capsule's own descriptors, passed through untouched.
    ///
    /// For a child that trusts what it is handed rather than opening the terminal itself.
    /// `tuicr` is the case, and the shell CLI is the evidence: it inherited, and worked.
    inherited,
};

pub const Options = struct {
    /// Inherited from capsule's own working directory when null.
    cwd: ?[]const u8 = null,
    terminal: Terminal = .own,
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

/// How a child that was handed the terminal ended.
///
/// `stopped` is here because `std.process.Child.wait` cannot express it: it calls `wait4`
/// with no options, and without `WUNTRACED` a stopped child never wakes the wait at all.
/// That is not a corner case. A child stopped by `SIGTTIN` or `SIGTTOU` is still holding
/// the terminal in raw mode while not running, so the event that wedges the terminal is
/// exactly the event a plain wait cannot see — capsule sat in `wait4` behind a stopped
/// `tuicr` until it was killed from a second terminal.
pub const Exit = union(enum) {
    exited: u8,
    /// Killed by a signal, which is carried rather than collapsed into one error: *which*
    /// signal is the entire diagnosis when a program that draws on the terminal dies during
    /// startup, and it is the fact the old `error.Signalled` threw away.
    signalled: std.posix.SIG,
    /// Stopped, then killed here so the terminal comes back.
    stopped: std.posix.SIG,

    /// The status capsule reports as its own. A child that did not exit normally becomes
    /// `128 + signal`, which is the convention a shell uses for the same thing.
    pub fn code(self: Exit) u8 {
        return switch (self) {
            .exited => |c| c,
            .signalled, .stopped => |s| {
                const n = std.math.cast(u7, @intFromEnum(s)) orelse return 1;
                return 128 + @as(u8, n);
            },
        };
    }

    /// The signal's name, or its number when the platform has no name for it.
    ///
    /// `std.posix.SIG` is a non-exhaustive enum, so `@tagName` panics on an unnamed value.
    /// That would be a panic on an error path, which is the worst place to put one.
    pub fn signalName(sig: std.posix.SIG, buf: []u8) []const u8 {
        if (std.enums.tagName(std.posix.SIG, sig)) |name| return name;
        return std.fmt.bufPrint(buf, "{d}", .{@intFromEnum(sig)}) catch "?";
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
pub fn interactive(io: Io, argv: []const []const u8, options: Options) Error!Exit {
    const tty = switch (options.terminal) {
        .own => openTty(io),
        .inherited => null,
    };
    defer if (tty) |t| t.close(io);

    const stdio: std.process.SpawnOptions.StdIo = if (tty) |t| .{ .file = t } else .inherit;

    // Captured before the handover and put back after it, on every path. A child that
    // exits cleanly restores the terminal itself and this changes nothing; one that is
    // killed or stopped mid-draw does not, and without this capsule returns you to a shell
    // with echo off and ctrl-c disabled — the state that took a second terminal to escape.
    //
    // An inherited handover has no `File` to ask, so stdin stands in for the terminal, the
    // same descriptor `tui/term.zig` treats as one. Not a terminal at all yields null here
    // and the restore is skipped, which is correct for a scripted run.
    const termios_fd: std.posix.fd_t = if (tty) |t| t.handle else std.posix.STDIN_FILENO;
    const saved: ?std.posix.termios = std.posix.tcgetattr(termios_fd) catch null;
    defer if (saved) |s| std.posix.tcsetattr(termios_fd, .FLUSH, s) catch {};

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (options.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = options.environ,
        .stdin = stdio,
        .stdout = stdio,
        .stderr = stdio,
    }) catch return error.SpawnFailed;

    return waitHandingOver(&child);
}

/// Waits for a child that holds the terminal, including the outcome `Child.wait` cannot
/// report.
///
/// `wait4` is called directly, with `WUNTRACED`, rather than through `child.wait`, which
/// passes no options: a stopped child does not wake an unflagged wait, so capsule blocks
/// behind a program that owns the terminal and is not running.
///
/// `SIGTSTP` is the one stop worth honouring — that is ctrl-z, and continuing the child
/// keeps job control working. `SIGTTIN` and `SIGTTOU` mean the opposite: the child cannot
/// use the terminal it was handed, and nothing is coming to resume it, so it is killed and
/// the reason is reported rather than waited on forever.
fn waitHandingOver(child: *std.process.Child) Error!Exit {
    const pid = child.id orelse return error.SpawnFailed;

    // `.file` and `.inherit` stdio open no pipes, so clearing the pid is the whole of the
    // stdlib's cleanup for this child. Doing it here stops a later wait or kill from acting
    // on a pid this function has already reaped.
    defer child.id = null;

    while (true) {
        var status: c_int = undefined;
        const rc = std.c.waitpid(pid, &status, std.posix.W.UNTRACED);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return error.SpawnFailed;
        }
        const raw: u32 = @bitCast(status);

        if (std.posix.W.IFSTOPPED(raw)) {
            const sig = std.posix.W.STOPSIG(raw);
            if (sig == .TSTP) {
                _ = std.c.kill(pid, .CONT);
                continue;
            }
            // Killed without a `SIGCONT` first: `SIGKILL` terminates a stopped process on
            // its own, and resuming it would open a window in which it runs again and
            // reaches some other fate, making which outcome is reported a race.
            _ = std.c.kill(pid, .KILL);
            var discard: c_int = undefined;
            _ = std.c.waitpid(pid, &discard, 0);
            return .{ .stopped = sig };
        }
        if (std.posix.W.IFEXITED(raw)) return .{ .exited = std.posix.W.EXITSTATUS(raw) };
        if (std.posix.W.IFSIGNALED(raw)) return .{ .signalled = std.posix.W.TERMSIG(raw) };
    }
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

test "a handed-over child that stops is reported and killed, not waited on forever" {
    // The regression this pins does not fail, it *hangs*: `std.process.Child.wait` calls
    // `wait4` with no options, so a stopped child never wakes it. That is what left capsule
    // parked in `wait4` behind a stopped `tuicr` that still owned the terminal.
    //
    // `exit 3` rather than nothing after the stop, so an implementation that resumed the
    // child instead of killing it fails here loudly rather than passing by luck.
    const ended = try interactive(testing.io, &.{ "/bin/sh", "-c", "kill -STOP $$; exit 3" }, .{});
    switch (ended) {
        .stopped => |s| try testing.expectEqual(std.posix.SIG.STOP, s),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u8, 128 + 17), ended.code());
}

test "a handed-over child killed by a signal names which one" {
    const ended = try interactive(testing.io, &.{ "/bin/sh", "-c", "kill -TERM $$" }, .{});
    switch (ended) {
        .signalled => |s| {
            try testing.expectEqual(std.posix.SIG.TERM, s);
            var buf: [16]u8 = undefined;
            try testing.expectEqualStrings("TERM", Exit.signalName(s, &buf));
        },
        else => return error.TestUnexpectedResult,
    }
    // The whole point of carrying the signal: `error.Signalled` collapsed this case, the
    // stop above, and an unknown status into one word that named none of them.
    try testing.expectEqual(@as(u8, 128 + 15), ended.code());
}

test "a normal exit still comes back as its own code" {
    const seven = try interactive(testing.io, &.{ "/bin/sh", "-c", "exit 7" }, .{});
    try testing.expectEqual(@as(u8, 7), seven.code());

    const zero = try interactive(testing.io, &.{ "/bin/sh", "-c", "exit 0" }, .{});
    try testing.expectEqual(@as(u8, 0), zero.code());
}

test "an inherited handover reports its child the same way an owned one does" {
    // What differs between the two is which descriptors the child gets, and nothing else:
    // a run under CI has no `/dev/tty` so both take the same branch here, which is the
    // point — the option must not become a second, quietly different wait path.
    const seven = try interactive(testing.io, &.{ "/bin/sh", "-c", "exit 7" }, .{ .terminal = .inherited });
    try testing.expectEqual(@as(u8, 7), seven.code());

    const killed = try interactive(testing.io, &.{ "/bin/sh", "-c", "kill -TERM $$" }, .{ .terminal = .inherited });
    switch (killed) {
        .signalled => |s| try testing.expectEqual(std.posix.SIG.TERM, s),
        else => return error.TestUnexpectedResult,
    }
}

test "a signal with no name on this platform still renders" {
    var buf: [16]u8 = undefined;
    // `std.posix.SIG` is non-exhaustive, so this value has no tag. `@tagName` would panic
    // on it, and it would panic while reporting an error, which is the worst moment.
    const nameless: std.posix.SIG = @enumFromInt(60);
    try testing.expectEqualStrings("60", Exit.signalName(nameless, &buf));
}

test "presence of a program is answered without throwing" {
    try testing.expect(present(testing.allocator, testing.io, "sh"));
    try testing.expect(!present(testing.allocator, testing.io, "definitely-not-a-real-program-xyz"));
}
