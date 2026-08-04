//! Running a resolved command: the guards, the context it gets, and the handlers.
//!
//! The guards are the reason this file exists. In bash each was a line repeated at the top
//! of thirty-eight functions (`host_only run start`, `need_daemon`, `vm_reachable`), which
//! meant a new command could silently forget one — and `run push` did, reaching the daemon
//! through `issue_branch` while declaring only `host_only need_remote`. Here they are
//! fields on the command, checked once, before the handler is entered.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Writer = std.Io.Writer;

const api = @import("api.zig");
const cli = @import("cli.zig");
const client = @import("client.zig");
const config = @import("config.zig");
const editor = @import("editor.zig");
const exec = @import("exec.zig");
const flake = @import("flake.zig");
const git = @import("git.zig");
const model = @import("model.zig");
const picker = @import("picker.zig");
const project_mod = @import("project.zig");
const run_mod = @import("run.zig");
const seed_mod = @import("seed.zig");
const ssh = @import("ssh.zig");
const template = @import("template.zig");
const vm = @import("vm.zig");

/// Everything a handler is allowed to reach. The repository is resolved once, by the
/// guard, rather than by each handler re-running `git rev-parse` the way `project_params`
/// did on every call.
pub const Ctx = struct {
    arena: std.mem.Allocator,
    io: Io,
    settings: config.Config,
    socket: []const u8,
    environ: *const std.process.Environ.Map,
    out: *Writer,
    err: *Writer,
    /// This executable's path, for the one case that re-launches it: starting a daemon
    /// with no service unit to do it. Carried from argv[0] because 0.16 has no selfExePath.
    exe: []const u8 = "capsule",
    /// Arguments after the group and verb.
    args: []const []const u8,
    /// Print the daemon's JSON rather than a rendered table.
    json: bool = false,
    /// Filled by the `project` guard; null when the command did not need one.
    repo: ?git.Repo = null,

    /// The ssh settings, from the same parsed config the daemon loads — which is what
    /// makes a CLI ssh reuse the master the daemon is already holding open.
    pub fn sshConfig(self: Ctx) ssh.Config {
        return ssh.configFrom(self.settings);
    }

    /// The two fields every project-scoped method carries.
    pub fn repoParams(self: Ctx) struct { git_common_dir: []const u8, cwd: []const u8 } {
        const r = self.repo.?;
        return .{ .git_common_dir = r.git_common_dir, .cwd = r.cwd };
    }

    pub fn fail(self: Ctx, comptime fmt: []const u8, args: anytype) u8 {
        self.err.print("capsule: " ++ fmt ++ "\n", args) catch {};
        return 1;
    }

    /// Empties the output buffers before something else takes the terminal.
    ///
    /// `out` is a 4 KiB buffered writer flushed at exit, while anything that takes over —
    /// ssh, qemu, tuicr, `$EDITOR`, a prompt on `/dev/tty` — writes to the file descriptor
    /// directly. Without this the ordering inverts: `capsule login` printed the
    /// instructions for what to do *inside* the container after the container had already
    /// exited. Go through the `hand*` helpers below rather than calling this by hand.
    pub fn flush(self: Ctx) void {
        self.out.flush() catch {};
        self.err.flush() catch {};
    }
};

/// The terminal handovers, each flushing first. They exist so that "flush before you hand
/// over" is a property of the call rather than a thing to remember at ten call sites.
fn handSshInteractive(ctx: *Ctx, remote: []const u8) exec.Error!u8 {
    ctx.flush();
    return ssh.interactive(ctx.arena, ctx.io, ctx.sshConfig(), remote);
}

fn handSshStream(ctx: *Ctx, remote: []const u8) exec.Error!u8 {
    ctx.flush();
    return ssh.stream(ctx.arena, ctx.io, ctx.sshConfig(), remote);
}

fn handSshInput(ctx: *Ctx, remote: []const u8, input: Io.File, seconds: u32) exec.Error!exec.Output {
    ctx.flush();
    return ssh.runWithInput(ctx.arena, ctx.io, ctx.sshConfig(), remote, input, seconds);
}

fn handStream(ctx: *Ctx, argv: []const []const u8) exec.Error!u8 {
    ctx.flush();
    return exec.stream(ctx.io, argv, .{});
}

fn handInteractive(ctx: *Ctx, argv: []const []const u8) exec.Error!u8 {
    ctx.flush();
    return exec.interactive(ctx.io, argv, .{});
}

fn handCapture(ctx: *Ctx, argv: []const []const u8) exec.Error!exec.Output {
    ctx.flush();
    return exec.interactiveCapture(ctx.arena, ctx.io, argv, .{});
}

/// Why a command was refused before it ran. Each maps to one message, in one place —
/// which is what stops "run capsule daemon start" being spelled six different ways.
pub const Refusal = enum {
    in_container,
    no_daemon,
    not_a_repo,
    vm_unreachable,
    not_local_vm,
    no_remote,

    pub fn message(self: Refusal) []const u8 {
        return switch (self) {
            .in_container => "this runs on the host, not inside the capsule",
            .no_daemon => "capsule is not running — run 'capsule daemon start'",
            .not_a_repo => "not a git repository",
            .vm_unreachable => "the VM is not reachable — run 'capsule vm start'",
            .not_local_vm => "this drives the local qemu VM, but CAPSULE_VM_HOST names another machine",
            .no_remote => "no 'vm' remote — run 'capsule run start' once to bootstrap",
        };
    }
};

/// Checks a command's declared needs, filling in `ctx.repo` on the way. Returns the first
/// refusal, or null when the command may run.
pub fn checkNeeds(ctx: *Ctx, cmd: *const cli.Command) ?Refusal {
    if (cmd.needs.host and inContainer(ctx.environ)) return .in_container;

    if (cmd.needs.qemu and !isLocalVm(ctx.settings.vm_host)) return .not_local_vm;

    if (cmd.needs.daemon) {
        const pong = api.call(ctx.arena, ctx.io, ctx.socket, api.ping, .{}) catch
            return .no_daemon;
        switch (pong) {
            .ok => {},
            .err => return .no_daemon,
        }
    }

    // Everything below addresses a project, so the repository is resolved once here.
    if (cmd.needs.daemon or cmd.needs.remote) {
        ctx.repo = git.discover(ctx.arena, ctx.io) catch return .not_a_repo;
    }

    if (cmd.needs.remote) {
        const g = git.Git{ .arena = ctx.arena, .io = ctx.io };
        if (!g.succeeds(&.{ "remote", "get-url", "vm" })) return .no_remote;
    }

    if (cmd.needs.vm and !vmReachable(ctx)) return .vm_unreachable;

    return null;
}

/// `CAPSULE_IN_CAPSULE` marks any container capsule started. `CAPSULE_PROJECT_DIR` marks a
/// run inside one and a login container has only the first — two variables, two jobs.
fn inContainer(environ: *const std.process.Environ.Map) bool {
    const v = environ.get("CAPSULE_IN_CAPSULE") orelse return false;
    return v.len > 0;
}

fn isLocalVm(vm_host: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, vm_host, '@') orelse return false;
    const host = vm_host[at + 1 ..];
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

/// Asks the daemon's world model, and falls back to ssh when there is no daemon to ask.
///
/// bash ran its own two-second `/dev/tcp` check here, giving capsule two notions of "the
/// VM is up" that could disagree: the daemon polls every few seconds over a warm
/// ControlMaster and already knows. Preferring the model keeps them from disagreeing —
/// but `vm ssh`, `vm gc`, `image pull` and `login` need a VM and *not* a daemon, and
/// refusing those with "the VM is not reachable" because capsuled is down names the wrong
/// problem entirely.
fn vmReachable(ctx: *Ctx) bool {
    if (api.call(ctx.arena, ctx.io, ctx.socket, api.world_get, .{})) |world| {
        switch (world) {
            .ok => |w| return w.reachable,
            .err => {},
        }
    } else |_| {}

    return ssh.reachable(ctx.arena, ctx.io, ctx.sshConfig());
}

/// Runs a resolved command, returning the process exit code.
pub fn run(ctx: *Ctx, cmd: *const cli.Command) u8 {
    if (checkNeeds(ctx, cmd)) |refusal| {
        return ctx.fail("{s}", .{refusal.message()});
    }

    if (!cmd.ported) {
        return ctx.fail(
            "'{s}{s}{s}' has not moved out of the shell CLI yet",
            .{ cmd.group, if (cmd.isBare()) "" else " ", cmd.verb },
        );
    }

    if (std.mem.eql(u8, cmd.group, "issue")) {
        if (std.mem.eql(u8, cmd.verb, "list")) return issueList(ctx);
        if (std.mem.eql(u8, cmd.verb, "new")) return issueNew(ctx);
        if (std.mem.eql(u8, cmd.verb, "comment")) return issueComment(ctx);
        if (std.mem.eql(u8, cmd.verb, "state")) return issueState(ctx);
        if (std.mem.eql(u8, cmd.verb, "rename")) return issueRename(ctx);
        if (std.mem.eql(u8, cmd.verb, "archive")) return issueArchive(ctx);
        if (std.mem.eql(u8, cmd.verb, "reopen")) return issueReopen(ctx);
        if (std.mem.eql(u8, cmd.verb, "edit")) return issueEdit(ctx);
        if (std.mem.eql(u8, cmd.verb, "triage")) return issueTriage(ctx);
    }
    if (std.mem.eql(u8, cmd.group, "memory")) {
        if (std.mem.eql(u8, cmd.verb, "list")) return memoryList(ctx);
        if (std.mem.eql(u8, cmd.verb, "review")) return memoryReview(ctx);
        if (std.mem.eql(u8, cmd.verb, "new")) return memoryNew(ctx);
    }
    if (std.mem.eql(u8, cmd.group, "project")) {
        if (std.mem.eql(u8, cmd.verb, "list")) return projectList(ctx);
        if (std.mem.eql(u8, cmd.verb, "add")) return projectAdd(ctx);
        if (std.mem.eql(u8, cmd.verb, "profile")) return projectProfile(ctx);
        if (std.mem.eql(u8, cmd.verb, "rm")) return projectRm(ctx);
    }
    if (std.mem.eql(u8, cmd.group, "daemon")) {
        if (std.mem.eql(u8, cmd.verb, "status")) return daemonStatus(ctx);
        if (std.mem.eql(u8, cmd.verb, "start")) return daemonStart(ctx);
        if (std.mem.eql(u8, cmd.verb, "stop")) return daemonStop(ctx);
    }
    if (std.mem.eql(u8, cmd.group, "env")) {
        if (std.mem.eql(u8, cmd.verb, "init")) return envInit(ctx);
        if (std.mem.eql(u8, cmd.verb, "add")) return envAdd(ctx);
        if (std.mem.eql(u8, cmd.verb, "rm")) return envRm(ctx);
        if (std.mem.eql(u8, cmd.verb, "update")) return envUpdate(ctx);
        if (std.mem.eql(u8, cmd.verb, "reload")) return envReload(ctx);
    }
    if (std.mem.eql(u8, cmd.group, "vm")) {
        if (std.mem.eql(u8, cmd.verb, "status")) return vmStatus(ctx);
        if (std.mem.eql(u8, cmd.verb, "ssh")) return vmSsh(ctx);
        if (std.mem.eql(u8, cmd.verb, "gc")) return vmGc(ctx);
        if (std.mem.eql(u8, cmd.verb, "start")) return vmStart(ctx);
        if (std.mem.eql(u8, cmd.verb, "stop")) return vmStop(ctx);
        if (std.mem.eql(u8, cmd.verb, "disk")) return vmDisk(ctx);
        if (std.mem.eql(u8, cmd.verb, "destroy")) return vmDestroy(ctx);
    }
    if (std.mem.eql(u8, cmd.group, "image")) {
        if (std.mem.eql(u8, cmd.verb, "pull")) return imagePull(ctx);
        if (std.mem.eql(u8, cmd.verb, "build")) return imageBuild(ctx);
    }
    if (std.mem.eql(u8, cmd.group, "login")) return login(ctx);
    if (std.mem.eql(u8, cmd.group, "run")) {
        if (std.mem.eql(u8, cmd.verb, "start")) return runStart(ctx);
        if (std.mem.eql(u8, cmd.verb, "attach")) return runAttach(ctx);
        if (std.mem.eql(u8, cmd.verb, "end")) return runEnd(ctx);
        if (std.mem.eql(u8, cmd.verb, "reset")) return runReset(ctx);
        if (std.mem.eql(u8, cmd.verb, "review")) return runReview(ctx);
        if (std.mem.eql(u8, cmd.verb, "list")) return runList(ctx);
        if (std.mem.eql(u8, cmd.verb, "fetch")) return runFetch(ctx);
        if (std.mem.eql(u8, cmd.verb, "push")) return runPush(ctx);
        if (std.mem.eql(u8, cmd.verb, "merge")) return runMerge(ctx);
    }

    return ctx.fail("'{s} {s}' is marked ported but has no handler", .{ cmd.group, cmd.verb });
}

/// Prints the daemon's raw JSON when `--json` was passed. The bash CLI printed raw JSON
/// unconditionally, which is why `issue new` answered a person with an escaped object.
fn emitJson(ctx: *Ctx, value: anytype) u8 {
    std.json.Stringify.value(value, api.stringify_options, ctx.out) catch return 1;
    ctx.out.writeAll("\n") catch return 1;
    return 0;
}

fn issueList(ctx: *Ctx) u8 {
    const filter: ?model.Issue.State = if (ctx.args.len > 0)
        model.Issue.State.parse(ctx.args[0]) orelse
            return ctx.fail("unknown state '{s}'", .{ctx.args[0]})
    else
        null;

    const p = ctx.repoParams();
    const response = api.call(ctx.arena, ctx.io, ctx.socket, api.issue_list, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .state = filter,
    }) catch |e| return ctx.fail("{t}", .{e});

    const rows = switch (response) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };
    if (ctx.json) return emitJson(ctx, rows);

    if (rows.len == 0) {
        ctx.out.writeAll("no issues yet — 'capsule issue new <title>'\n") catch {};
        return 0;
    }
    for (rows) |row| writeIssueLine(ctx, row);
    return 0;
}

/// The width the state column is padded to, so a single issue printed after a verb lines
/// up with the same issue in `issue list`. `ready_for_review` is the longest state at 16.
const state_column = 17;

/// One line per issue, used by both the list and the verbs that echo what they changed.
/// Two renderers drifted apart the moment they existed separately.
fn writeIssueLine(ctx: *Ctx, issue: api.Issue) void {
    const line = std.fmt.comptimePrint("{{s}}  {{s: <{d}}}{{s}}\n", .{state_column});
    ctx.out.print(line, .{ issue.short, @tagName(issue.state), issue.title }) catch {};
}

/// Renders one issue the way a person reads it, after a verb changed it.
fn showIssue(ctx: *Ctx, issue: api.Issue) u8 {
    if (ctx.json) return emitJson(ctx, issue);
    writeIssueLine(ctx, issue);
    return 0;
}

/// Sends a method whose result is one issue, and renders it. Every mutating issue verb has
/// this shape, which in bash was five near-identical blocks of jq.
fn issueCall(ctx: *Ctx, comptime M: type, params: M.Params) u8 {
    const response = api.call(ctx.arena, ctx.io, ctx.socket, M, params) catch |e|
        return ctx.fail("{t}", .{e});
    return switch (response) {
        .ok => |issue| showIssue(ctx, issue),
        .err => |f| failure(ctx, f),
    };
}

/// Resolves the id an issue verb acts on, turning "no terminal to pick with" and "nothing
/// chosen" into the right message rather than an error trace.
fn issueTarget(ctx: *Ctx, given: ?[]const u8, states: []const State) ?[]const u8 {
    return resolveIssue(ctx, given, states) catch |e| switch (e) {
        error.NeedsIssueId => {
            _ = ctx.fail("no issue id given, and there is no terminal to pick one on", .{});
            return null;
        },
        else => {
            _ = ctx.fail("{t}", .{e});
            return null;
        },
    } orelse {
        ctx.out.writeAll("nothing selected\n") catch {};
        return null;
    };
}

fn issueNew(ctx: *Ctx) u8 {
    if (ctx.args.len == 0) return ctx.fail("an issue needs a title", .{});
    const title = std.mem.join(ctx.arena, " ", ctx.args) catch return 1;

    const result = editText(ctx, "", "<!-- describe the issue. save to create it, empty aborts. -->") catch |e|
        return ctx.fail("editor failed: {t}", .{e});
    if (result.outcome != .changed) {
        ctx.out.writeAll("aborted — nothing created\n") catch {};
        return 1;
    }

    const p = ctx.repoParams();
    return issueCall(ctx, api.issue_new, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .title = title,
        .body = result.text,
    });
}

fn issueComment(ctx: *Ctx) u8 {
    const id = issueTarget(ctx, if (ctx.args.len > 0) ctx.args[0] else null, any_state) orelse return 1;

    const result = editText(ctx, "", "<!-- your note. save to add it, empty aborts. -->") catch |e|
        return ctx.fail("editor failed: {t}", .{e});
    if (result.outcome != .changed) {
        ctx.out.writeAll("aborted — nothing added\n") catch {};
        return 1;
    }

    const p = ctx.repoParams();
    return issueCall(ctx, api.issue_comment, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
        .text = result.text,
    });
}

/// `issue state [id] <state>` — the id is optional, so the single-argument form has to be
/// disambiguated by whether the word names a state.
fn issueState(ctx: *Ctx) u8 {
    var given: ?[]const u8 = null;
    var wanted: ?State = null;

    if (ctx.args.len == 1) {
        wanted = State.parse(ctx.args[0]);
        if (wanted == null) return ctx.fail("unknown state '{s}'", .{ctx.args[0]});
    } else if (ctx.args.len >= 2) {
        given = ctx.args[0];
        wanted = State.parse(ctx.args[1]) orelse
            return ctx.fail("unknown state '{s}'", .{ctx.args[1]});
    } else {
        return ctx.fail("which state? open, in_progress, blocked, ready_for_review", .{});
    }

    const id = issueTarget(ctx, given, any_state) orelse return 1;
    const p = ctx.repoParams();
    return issueCall(ctx, api.issue_state, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
        .state = wanted.?,
    });
}

/// `issue rename [id] <title>` — a title never goes through the editor, because it is one
/// line and a malformed edit silently renaming an issue buys nothing.
fn issueRename(ctx: *Ctx) u8 {
    if (ctx.args.len == 0) return ctx.fail("a new title is needed", .{});

    // An id is eight hex characters; anything else starts the title.
    const has_id = ctx.args.len >= 2 and looksLikeId(ctx.args[0]);
    const given: ?[]const u8 = if (has_id) ctx.args[0] else null;
    const words = if (has_id) ctx.args[1..] else ctx.args;
    const title = std.mem.join(ctx.arena, " ", words) catch return 1;

    const id = issueTarget(ctx, given, any_state) orelse return 1;
    const p = ctx.repoParams();
    return issueCall(ctx, api.issue_rename, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
        .title = title,
    });
}

fn issueArchive(ctx: *Ctx) u8 {
    var given: ?[]const u8 = null;
    var reason: []const u8 = "";

    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        if (std.mem.eql(u8, ctx.args[i], "-m")) {
            i += 1;
            if (i >= ctx.args.len) return ctx.fail("archiving needs a reason after -m", .{});
            reason = std.mem.join(ctx.arena, " ", ctx.args[i..]) catch return 1;
            break;
        }
        if (given == null) given = ctx.args[i];
    }
    if (reason.len == 0) return ctx.fail("archiving needs a reason (-m)", .{});

    const id = issueTarget(ctx, given, any_state) orelse return 1;
    const p = ctx.repoParams();
    return issueCall(ctx, api.issue_archive, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
        .reason = reason,
    });
}

fn issueReopen(ctx: *Ctx) u8 {
    const id = issueTarget(ctx, if (ctx.args.len > 0) ctx.args[0] else null, archived_only) orelse return 1;
    const p = ctx.repoParams();
    return issueCall(ctx, api.issue_reopen, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
        .reason = "",
    });
}

/// Reads the issue, opens its body, writes it back with the `last_event_id` it was read
/// at — the optimistic-concurrency token that turns a concurrent change into a `conflict`
/// rather than a silent overwrite.
fn issueEdit(ctx: *Ctx) u8 {
    const id = issueTarget(ctx, if (ctx.args.len > 0) ctx.args[0] else null, any_state) orelse return 1;
    const p = ctx.repoParams();

    const got = api.call(ctx.arena, ctx.io, ctx.socket, api.issue_get, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
    }) catch |e| return ctx.fail("{t}", .{e});

    const current = switch (got) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };

    const header = std.fmt.allocPrint(
        ctx.arena,
        "<!-- {s}  {s} — edit the body. save to apply, empty aborts. -->",
        .{ current.short, current.title },
    ) catch return 1;

    const result = editText(ctx, current.body, header) catch |e|
        return ctx.fail("editor failed: {t}", .{e});
    if (result.outcome != .changed) {
        ctx.out.writeAll("unchanged — nothing applied\n") catch {};
        return 0;
    }

    return issueCall(ctx, api.issue_edit, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
        .body = result.text,
        .last_event_id = current.last_event_id,
    });
}

/// Eight or more hex characters, which is what `issue list` prints and what a person
/// pastes. Anything else in the first position is the start of a title.
fn looksLikeId(word: []const u8) bool {
    if (word.len < 4 or word.len > 32) return false;
    for (word) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// How many times a rejected buffer is re-opened before giving up. Three is bash's
/// number: enough to fix a typo, few enough that a buffer nobody can satisfy still ends.
const review_attempts = 3;

/// The `rebase -i`-style edit loop, shared by issue triage and memory review.
///
/// bash had this twice, near-verbatim, differing only in the method names and the closing
/// message. The interesting part is the retry: a buffer the daemon rejects is re-opened
/// with the complaint prepended as an HTML comment and **the user's text intact**, rather
/// than being discarded or half-applied.
///
/// Returns null when the user aborted, left the buffer unchanged, or ran out of attempts —
/// all of which have already been reported to them.
fn editAndApply(
    ctx: *Ctx,
    comptime Apply: type,
    initial: []const u8,
) ?Apply.Result {
    const p = ctx.repoParams();
    var buffer = initial;

    var attempt: usize = 0;
    while (attempt < review_attempts) : (attempt += 1) {
        const edited = editText(ctx, buffer, "") catch |e| {
            _ = ctx.fail("editor failed: {t}", .{e});
            return null;
        };
        switch (edited.outcome) {
            .changed => {},
            .unchanged => {
                ctx.out.writeAll("unchanged — nothing applied\n") catch {};
                return null;
            },
            .aborted, .discarded => {
                ctx.out.writeAll("aborted — nothing applied\n") catch {};
                return null;
            },
        }

        const response = api.call(ctx.arena, ctx.io, ctx.socket, Apply, .{
            .git_common_dir = p.git_common_dir,
            .cwd = p.cwd,
            .buffer = edited.text,
        }) catch |e| {
            _ = ctx.fail("{t}", .{e});
            return null;
        };

        switch (response) {
            .ok => |result| return result,
            .err => |f| {
                // Keep what they wrote and put the complaint where they will read it.
                buffer = std.fmt.allocPrint(ctx.arena, "<!-- {s} -->\n{s}", .{
                    f.message, edited.text,
                }) catch return null;
            },
        }
    }

    _ = ctx.fail("the buffer was refused {d} times — nothing applied", .{review_attempts});
    return null;
}

fn issueTriage(ctx: *Ctx) u8 {
    const p = ctx.repoParams();
    const loaded = api.call(ctx.arena, ctx.io, ctx.socket, api.issue_triage_load, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e});

    const buffer = switch (loaded) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };
    if (buffer.count == 0) {
        ctx.out.writeAll("nothing awaiting triage\n") catch {};
        return 0;
    }

    const applied = editAndApply(ctx, api.issue_triage_apply, buffer.buffer) orelse return 1;
    if (ctx.json) return emitJson(ctx, applied);
    ctx.out.print("{d} accepted, {d} rejected\n", .{ applied.accepted, applied.rejected }) catch {};
    return 0;
}

fn memoryReview(ctx: *Ctx) u8 {
    const p = ctx.repoParams();
    const loaded = api.call(ctx.arena, ctx.io, ctx.socket, api.memory_review_load, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e});

    const buffer = switch (loaded) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };
    if (buffer.proposals == 0 and buffer.active == 0) {
        ctx.out.writeAll("no memories to review\n") catch {};
        return 0;
    }

    const applied = editAndApply(ctx, api.memory_review_apply, buffer.buffer) orelse return 1;
    if (ctx.json) return emitJson(ctx, applied);
    ctx.out.print("{d} changed\n", .{applied.changed}) catch {};
    return 0;
}

fn memoryList(ctx: *Ctx) u8 {
    const p = ctx.repoParams();
    const response = api.call(ctx.arena, ctx.io, ctx.socket, api.memory_list, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e});

    const rows = switch (response) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };
    if (ctx.json) return emitJson(ctx, rows);

    if (rows.len == 0) {
        ctx.out.writeAll("no memories yet — 'capsule memory new'\n") catch {};
        return 0;
    }
    for (rows) |row| {
        // The body is one paragraph by convention but not by rule, so only its first line
        // goes in the table; `memory review` is where the whole thing is read.
        const first = std.mem.sliceTo(row.body, '\n');
        ctx.out.print("{s}  {s: <10}{s}\n", .{ row.short, @tagName(row.state), first }) catch {};
    }
    return 0;
}

fn memoryNew(ctx: *Ctx) u8 {
    const result = editText(ctx, "", "<!-- one memory. save to add it, empty aborts. -->") catch |e|
        return ctx.fail("editor failed: {t}", .{e});
    if (result.outcome != .changed) {
        ctx.out.writeAll("aborted — nothing added\n") catch {};
        return 1;
    }

    const p = ctx.repoParams();
    const response = api.call(ctx.arena, ctx.io, ctx.socket, api.memory_new, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .body = result.text,
        .anchors = "",
    }) catch |e| return ctx.fail("{t}", .{e});

    return switch (response) {
        .ok => {
            ctx.out.writeAll("added\n") catch {};
            return 0;
        },
        .err => |f| failure(ctx, f),
    };
}

fn runList(ctx: *Ctx) u8 {
    const p = ctx.repoParams();
    const response = api.call(ctx.arena, ctx.io, ctx.socket, api.run_list, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e});

    const rows = switch (response) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };
    if (ctx.json) return emitJson(ctx, rows);

    if (rows.len == 0) {
        ctx.out.writeAll("no runs on this project yet\n") catch {};
        return 0;
    }
    for (rows) |row| {
        ctx.out.print("{s}  {s: <11}issue {s}  {s}\n", .{
            row.short, @tagName(row.state), row.issue, row.branch,
        }) catch {};
    }
    return 0;
}

fn runFetch(ctx: *Ctx) u8 {
    const g = git.Git{ .arena = ctx.arena, .io = ctx.io };
    const out = git.fetch(g) catch |e| return ctx.fail("{t}", .{e});
    if (!out.ok()) return ctx.fail("git fetch failed: {s}", .{out.trimmedErr()});
    ctx.out.writeAll("fetched\n") catch {};
    return 0;
}

/// Pushes HEAD onto an issue's branch in the replica.
///
/// The full id has to be asked for: the branch name is built from all 32 hex characters,
/// and what a person types (or picks) is the eight-character short form. bash paid the
/// same round trip, then failed with a raw error because its guard never declared the
/// daemon it needs — the command table now does.
fn runPush(ctx: *Ctx) u8 {
    const id = issueTarget(ctx, if (ctx.args.len > 0) ctx.args[0] else null, any_state) orelse return 1;
    const p = ctx.repoParams();

    const got = api.call(ctx.arena, ctx.io, ctx.socket, api.issue_get, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
    }) catch |e| return ctx.fail("{t}", .{e});

    const issue = switch (got) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };

    const branch = git.issueBranch(ctx.arena, issue.id) catch return 1;
    const g = git.Git{ .arena = ctx.arena, .io = ctx.io };
    const out = git.pushToBranch(g, branch) catch |e| return ctx.fail("{t}", .{e});
    if (!out.ok()) return ctx.fail("git push failed: {s}", .{out.trimmedErr()});

    ctx.out.print("pushed onto {s}\n", .{branch}) catch {};
    return 0;
}

/// Squash-merges an issue's branch, then marks the issue done.
///
/// The merge is a squash rather than `--no-ff`: one commit with a message you author lands
/// on your branch, and the agent's granular commits stay out of your history.
///
/// Order matters and is deliberate. The store is told **after** git has committed, because
/// a run marked done against a merge that did not happen is the worse of the two
/// inconsistencies — you can re-run the merge, but you cannot un-tell the backlog.
fn runMerge(ctx: *Ctx) u8 {
    const id = issueTarget(ctx, if (ctx.args.len > 0) ctx.args[0] else null, ready_only) orelse return 1;
    const p = ctx.repoParams();
    const g = git.Git{ .arena = ctx.arena, .io = ctx.io };

    const got = api.call(ctx.arena, ctx.io, ctx.socket, api.issue_get, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
    }) catch |e| return ctx.fail("{t}", .{e});
    const issue = switch (got) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };

    _ = git.fetch(g) catch {};

    const branch = git.issueBranch(ctx.arena, issue.id) catch return 1;
    const remote_ref = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ git.remote, branch }) catch return 1;
    if (!git.hasRef(g, remote_ref)) {
        return ctx.fail("nothing to merge: {s} does not exist in the replica", .{remote_ref});
    }

    const range = std.fmt.allocPrint(ctx.arena, "HEAD..{s}", .{remote_ref}) catch return 1;
    const count = git.countCommits(g, range);
    if (count == 0) {
        ctx.out.print("nothing to merge — {s} adds no commits\n", .{remote_ref}) catch {};
        return 0;
    }

    if (g.capture(&.{ "log", "--oneline", range })) |log| {
        ctx.out.print("{s}\n", .{log}) catch {};
    } else |_| {}
    if (g.capture(&.{ "diff", "--stat", range })) |stat| {
        ctx.out.print("{s}\n\n", .{stat}) catch {};
    } else |_| {}

    const header = std.fmt.allocPrint(
        ctx.arena,
        "<!-- the squash commit message. save to merge, empty aborts. -->",
        .{},
    ) catch return 1;
    const message = editText(ctx, issue.title, header) catch |e|
        return ctx.fail("editor failed: {t}", .{e});

    const commit_message = switch (message.outcome) {
        .changed => message.text,
        // Leaving the seeded title alone is a decision, not an abort: it is already a
        // reasonable commit message. Only an emptied buffer means "stop".
        .unchanged => issue.title,
        .aborted, .discarded => {
            ctx.out.writeAll("aborted — nothing merged\n") catch {};
            return 1;
        },
    };

    const squash = g.run(&.{ "merge", "--squash", remote_ref }) catch |e|
        return ctx.fail("{t}", .{e});
    if (!squash.ok()) {
        return ctx.fail("merge failed: {s}", .{squash.trimmedErr()});
    }

    const commit = g.run(&.{ "commit", "-q", "-m", commit_message }) catch |e|
        return ctx.fail("{t}", .{e});
    if (!commit.ok()) {
        return ctx.fail("commit failed: {s}", .{commit.trimmedErr()});
    }

    const marked = api.call(ctx.arena, ctx.io, ctx.socket, api.issue_merge, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
        .commit = commit_message,
    }) catch |e| {
        // The merge landed. Say so plainly rather than reading as though nothing happened.
        return ctx.fail("merged, but the issue could not be marked done: {t}", .{e});
    };
    switch (marked) {
        .ok => {},
        .err => |f| {
            ctx.err.writeAll("capsule: merged, but the issue could not be marked done\n") catch {};
            return failure(ctx, f);
        },
    }

    ctx.out.print("merged {s} onto {s}\n", .{ issue.short, currentBranch(g) }) catch {};

    const main_branch = git.defaultBranch(g, ctx.settings.main_branch) catch "";
    if (main_branch.len > 0 and std.mem.eql(u8, main_branch, currentBranch(g))) {
        resyncReplica(ctx, g, ctx.repo.?, main_branch);
    }
    return 0;
}

/// Pushes the merge to the replica and moves it onto the main branch, so the agent's next
/// run starts from the merge rather than from the tip it committed on.
///
/// Nothing here can fail the command. It runs *after* `git commit`, and bash ran it there
/// too — under `set -e`, with a `capsuled project.get` in a command substitution as its
/// first act. A daemon hiccup at that moment killed the script with the merge already
/// committed and the replica un-synced: precisely the state this exists to prevent. Every
/// step below reports and returns instead, which is the structural fix.
fn resyncReplica(ctx: *Ctx, g: git.Git, p: git.Repo, main_branch: []const u8) void {
    const got = api.call(ctx.arena, ctx.io, ctx.socket, api.project_get, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch {
        ctx.err.writeAll("capsule: merged, but the replica could not be looked up — it stays on the pre-merge tip\n") catch {};
        return;
    };
    const replica = switch (got) {
        .ok => |v| v.replica,
        .err => {
            ctx.err.writeAll("capsule: merged, but the replica could not be looked up — it stays on the pre-merge tip\n") catch {};
            return;
        },
    };
    if (replica.len == 0) return;

    const refspec = std.fmt.allocPrint(ctx.arena, "HEAD:{s}", .{main_branch}) catch return;
    const pushed = g.run(&.{ "push", "-q", git.remote, refspec }) catch {
        ctx.err.writeAll("capsule: merged, but the replica would not accept the push\n") catch {};
        return;
    };
    if (!pushed.ok()) {
        ctx.err.print("capsule: merged, but the replica would not accept the push: {s}\n", .{
            pushed.trimmedErr(),
        }) catch {};
        return;
    }

    const remote = std.fmt.allocPrint(ctx.arena, "git -C ~/capsule/{s} checkout -q {s}", .{
        ssh.shellQuote(ctx.arena, replica) catch return,
        ssh.shellQuote(ctx.arena, main_branch) catch return,
    }) catch return;

    const out = ssh.run(ctx.arena, ctx.io, ctx.sshConfig(), remote, 30) catch {
        ctx.out.writeAll("capsule: VM is down — the replica will be stale until the next run\n") catch {};
        return;
    };
    if (out.ok()) {
        ctx.out.print("replica synced — now on {s}\n", .{main_branch}) catch {};
        return;
    }

    ctx.err.print(
        "capsule: merged and pushed, but the replica would not switch to {s}.\n" ++
            "         its working tree is probably dirty — 'capsule run attach' and commit or\n" ++
            "         stash there, or 'capsule vm ssh' to look.\n",
        .{main_branch},
    ) catch {};
}

fn currentBranch(g: git.Git) []const u8 {
    return g.capture(&.{ "rev-parse", "--abbrev-ref", "HEAD" }) catch "HEAD";
}

/// How the daemon is supervised on this machine. Detected rather than configured, because
/// which one is present is a property of the install, not a choice the user makes.
const Service = enum {
    launchd,
    systemd,
    /// No unit installed — `nix run` and a checkout both land here, so the daemon is
    /// started as a plain detached process.
    none,
};

const launchd_label = "dev.capsule.capsuled";
const systemd_unit = "capsuled.service";

/// Which supervisor owns *this* daemon, or `.none`.
///
/// `CAPSULE_SOCKET` being set is decisive: the installed unit listens on the default
/// socket, so if the CLI has been pointed somewhere else, the unit is a different daemon
/// and must not be signalled. Getting this wrong kills the daemon the user depends on and
/// leaves launchd restarting it in a loop.
fn serviceManager(ctx: *Ctx) Service {
    if (ctx.environ.get("CAPSULE_SOCKET")) |s| {
        if (s.len > 0) return .none;
    }

    if (@import("builtin").os.tag == .macos) {
        const target = std.fmt.allocPrint(ctx.arena, "gui/{d}/{s}", .{
            std.c.getuid(), launchd_label,
        }) catch return .none;
        if (exec.run(ctx.arena, ctx.io, &.{ "launchctl", "print", target }, .{})) |out| {
            if (out.ok()) return .launchd;
        } else |_| {}
        return .none;
    }

    if (exec.run(ctx.arena, ctx.io, &.{ "systemctl", "--user", "cat", systemd_unit }, .{})) |out| {
        if (out.ok()) return .systemd;
    } else |_| {}
    return .none;
}

/// A connect, not a `ping`: this is called in a poll loop, and a daemon mid-shutdown
/// accepts without replying. See `client.alive`.
fn daemonAlive(ctx: *Ctx) bool {
    return client.alive(ctx.socket);
}

/// Starts the daemon through whatever supervises it, then waits for it to answer.
///
/// The wait is what makes this useful: without it, the very next command races the
/// daemon's socket and fails with "capsule is not running" for reasons nobody can see.
fn daemonStart(ctx: *Ctx) u8 {
    if (daemonAlive(ctx)) {
        ctx.out.writeAll("already running\n") catch {};
        return 0;
    }

    switch (serviceManager(ctx)) {
        .launchd => {
            const target = std.fmt.allocPrint(ctx.arena, "gui/{d}/{s}", .{
                std.c.getuid(), launchd_label,
            }) catch return 1;
            _ = exec.run(ctx.arena, ctx.io, &.{ "launchctl", "kickstart", target }, .{}) catch {};
        },
        .systemd => {
            _ = exec.run(ctx.arena, ctx.io, &.{ "systemctl", "--user", "start", systemd_unit }, .{}) catch {};
        },
        .none => {
            // Detached from this process's stdio, so quitting the shell that started it
            // does not take the daemon with it.
            const self = ctx.exe;
            // `pgid = 0` puts the daemon in its own process group, which is what bash's
            // `setsid` was for: without it the child belongs to this command's job and
            // dies with it, so the daemon binds its socket and then vanishes.
            //
            // stderr goes to a log rather than /dev/null — a daemon that fails to start
            // must be able to say why, and discarding it makes every later symptom
            // unattributable.
            const log_path = std.fmt.allocPrint(ctx.arena, "{s}/daemon.log", .{
                std.fs.path.dirname(ctx.socket) orelse ".",
            }) catch return 1;
            // Orphaned deliberately, through a shell that backgrounds it and exits.
            //
            // Spawning the daemon directly does not survive: it binds its socket, answers
            // one probe, and dies the moment this process returns. An intermediate shell
            // exits immediately, so the daemon is reparented to init and belongs to
            // nobody — which is what `setsid capsuled daemon &` bought in the shell CLI.
            const script = std.fmt.allocPrint(
                ctx.arena,
                "exec \"$1\" daemon >>\"$2\" 2>&1 &",
                .{},
            ) catch return 1;

            var child = std.process.spawn(ctx.io, .{
                .argv = &.{ "/bin/sh", "-c", script, "sh", self, log_path },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch return ctx.fail("could not start the daemon", .{});
            // Reaped here so the shell does not linger as a zombie; the daemon it left
            // behind is already detached.
            _ = child.wait(ctx.io) catch {};
        },
    }

    if (waitForDaemon(ctx, true, 50)) {
        ctx.out.writeAll("daemon started\n") catch {};
        return 0;
    }
    return ctx.fail(
        "nothing is answering on {s} — try 'capsule daemon' in the foreground to see why",
        .{ctx.socket},
    );
}

/// Polls until the daemon's liveness matches `want`, or the attempts run out. Returns
/// whether it got there.
fn waitForDaemon(ctx: *Ctx, want: bool, attempts: usize) bool {
    var i: usize = 0;
    while (i < attempts) : (i += 1) {
        if (daemonAlive(ctx) == want) return true;
        std.Io.sleep(ctx.io, .fromMilliseconds(100), .awake) catch {};
    }
    return daemonAlive(ctx) == want;
}

/// Stops the daemon, and says so only once it has actually gone.
///
/// Two things make this less obvious than it looks. A supervisor may own a *different*
/// daemon than the one this CLI is talking to — `CAPSULE_SOCKET` points somewhere else,
/// or the launchd unit is installed while a checkout runs its own — so the supervisor is
/// tried first and the socket is then checked rather than trusted. And `daemon.stop` over
/// the socket by construction reaches exactly the daemon we are connected to, which makes
/// it the right fallback rather than the special case.
fn daemonStop(ctx: *Ctx) u8 {
    if (!daemonAlive(ctx)) {
        ctx.out.writeAll("not running\n") catch {};
        return 0;
    }

    switch (serviceManager(ctx)) {
        .launchd => {
            const target = std.fmt.allocPrint(ctx.arena, "gui/{d}/{s}", .{
                std.c.getuid(), launchd_label,
            }) catch return 1;
            _ = exec.run(ctx.arena, ctx.io, &.{ "launchctl", "kill", "TERM", target }, .{}) catch {};
        },
        .systemd => {
            _ = exec.run(ctx.arena, ctx.io, &.{ "systemctl", "--user", "stop", systemd_unit }, .{}) catch {};
        },
        .none => {},
    }

    if (waitForDaemon(ctx, false, 10)) {
        ctx.out.writeAll("daemon stopped\n") catch {};
        return 0;
    }

    // Still answering, so whatever the supervisor stopped was not this one.
    _ = api.call(ctx.arena, ctx.io, ctx.socket, api.daemon_stop, .{}) catch {};
    if (waitForDaemon(ctx, false, 20)) {
        ctx.out.writeAll("daemon stopped\n") catch {};
        return 0;
    }

    return ctx.fail("the daemon is still answering on {s}", .{ctx.socket});
}

/// Reads `flake.nix` from the working directory, or says why it could not.
fn readFlake(ctx: *Ctx) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(ctx.io, "flake.nix", ctx.arena, .limited(1 << 20)) catch {
        _ = ctx.fail("no flake.nix here — 'capsule env init' scaffolds one", .{});
        return null;
    };
}

/// Writes `flake.nix` back.
///
/// Written through a temp file in the same directory and renamed, so an interrupted write
/// cannot leave a half-rewritten flake — bash's `mktemp ./flake.nix.XXXXXX` had the same
/// intent but no trap, so a crash between the two left the debris behind.
fn writeFlake(ctx: *Ctx, contents: []const u8) bool {
    const dir = Io.Dir.cwd();
    const tmp = "flake.nix.capsule-tmp";

    var file = dir.createFile(ctx.io, tmp, .{ .truncate = true }) catch {
        _ = ctx.fail("cannot write to this directory", .{});
        return false;
    };
    var ok = true;
    {
        defer file.close(ctx.io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(ctx.io, &buf);
        w.interface.writeAll(contents) catch {
            ok = false;
        };
        w.interface.flush() catch {
            ok = false;
        };
    }
    if (!ok) {
        dir.deleteFile(ctx.io, tmp) catch {};
        _ = ctx.fail("could not write flake.nix", .{});
        return false;
    }

    dir.rename(tmp, dir, "flake.nix", ctx.io) catch {
        dir.deleteFile(ctx.io, tmp) catch {};
        _ = ctx.fail("could not replace flake.nix", .{});
        return false;
    };
    return true;
}

/// `direnv reload`, best-effort. A devshell that has not been entered yet has nothing to
/// reload, and failing the whole command over that would be wrong.
fn direnvReload(ctx: *Ctx) void {
    const code = handStream(ctx, &.{ "direnv", "reload" }) catch return;
    if (code != 0) {
        ctx.err.writeAll("capsule: direnv reload did not succeed — run it yourself\n") catch {};
    }
}

/// The states `run start`'s picker offers.
///
/// `in_progress` and `blocked` are here alongside `open` because a run that died leaves
/// its issue in one of them, and re-dispatching is how it resumes.
const startable: []const State = &.{ .open, .in_progress, .blocked };

/// `run start` — dispatch an issue to an agent.
///
/// Thirteen ssh round trips in bash, two here plus the `git push` between them. The push
/// is the seam: git owns that connection, the replica must exist before it, and the
/// checkout must follow it.
fn runStart(ctx: *Ctx) u8 {
    const p = ctx.repoParams();
    const g = git.Git{ .arena = ctx.arena, .io = ctx.io };

    const project = switch (api.call(ctx.arena, ctx.io, ctx.socket, api.project_get, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e})) {
        .ok => |v| v,
        .err => return ctx.fail("not a registered project — 'capsule project add' here first", .{}),
    };

    const id = issueTarget(ctx, if (ctx.args.len > 0) ctx.args[0] else null, startable) orelse return 1;

    const started = switch (api.call(ctx.arena, ctx.io, ctx.socket, api.run_start, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .issue = id,
    }) catch |e| return ctx.fail("{t}", .{e})) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };

    // `capsule-<12 hex>` and `runs/<12 hex>` are cut from the same run id, which is what
    // lets `report_session_end` recover one name from the other.
    const run_dir = std.fmt.allocPrint(ctx.arena, ".capsule/runs/{s}", .{
        started.run[0..@min(12, started.run.len)],
    }) catch return 1;

    // The VM's home has to be known before the seed can be written, because the seeded
    // agent state names the project by its path there. It comes back from the bootstrap.
    const boot = bootstrapVm(ctx, project.replica, run_dir) orelse return 1;

    if (!pushToReplica(ctx, g, project.replica, started.branch)) return 1;

    const project_dir = std.fmt.allocPrint(ctx.arena, "{s}/capsule/{s}", .{ boot.home, project.replica }) catch return 1;
    const short = shortId(started.issue);

    const seed_dir = buildSeed(ctx, started, project.profile, project_dir) orelse return 1;
    defer removeSeed(ctx, seed_dir);

    const tarball = packSeed(ctx, seed_dir) orelse return 1;
    defer tarball.close(ctx.io);

    ctx.out.print("\n  capsule  {s}  {s}\n  {s}\n\n", .{ short, started.title, started.branch }) catch {};

    const container_cmd = run_mod.commandLine(ctx.arena, run_mod.podmanArgs(ctx.arena, .{
        .image = ctx.settings.image,
        .container_home = ctx.settings.container_home,
        .mcp_port = ctx.settings.mcp_port,
        .container_name = started.container,
        .project_dir = project_dir,
        .agent_state_dir = std.fmt.allocPrint(ctx.arena, "{s}/{s}/claude", .{ boot.home, run_dir }) catch return 1,
        .env_file = std.fmt.allocPrint(ctx.arena, "{s}/{s}/env", .{ boot.home, run_dir }) catch return 1,
        .profile = project.profile,
        .issue_short = short,
        .git_config_path = boot.gitconfig,
    }) catch return 1) catch return 1;

    const launch = run_mod.launchScript(ctx.arena, .{
        .replica = project.replica,
        .branch = started.branch,
        .run_dir = run_dir,
        .container_cmd = container_cmd,
    }) catch return 1;

    const out = handSshInput(ctx, launch, tarball, 180) catch |e|
        return ctx.fail("ssh failed: {t}", .{e});
    if (!out.ok()) return ctx.fail("the container did not start (exit {d})", .{out.code});

    return runAttach(ctx);
}

/// The last 8 characters of an id — the short form ids are displayed and resolved by.
fn shortId(id: []const u8) []const u8 {
    return if (id.len <= 8) id else id[id.len - 8 ..];
}

/// `run attach` — reconnect to the live run.
fn runAttach(ctx: *Ctx) u8 {
    const container = liveContainer(ctx) orelse return ctx.fail(
        "no run is live on this project — 'capsule run start' to begin one",
        .{},
    );

    const cmd = run_mod.commandLine(ctx.arena, run_mod.attachArgs(ctx.arena, container) catch return 1) catch return 1;

    // A session that ended rather than detached exits non-zero, and that is not a failure
    // of the command — it is the normal way a run finishes. bash needed an explicit
    // `|| true` here to stop `set -e` taking the script down before it could say so.
    _ = handSshInteractive(ctx, cmd) catch |e|
        return ctx.fail("ssh failed: {t}", .{e});

    const still_there = std.fmt.allocPrint(ctx.arena, "podman container exists {s}", .{
        ssh.shellQuote(ctx.arena, container) catch return 1,
    }) catch return 1;

    if (ssh.run(ctx.arena, ctx.io, ctx.sshConfig(), still_there, 30)) |probe| {
        if (probe.ok()) {
            ctx.out.writeAll(
                "capsule: detached — the agent is still running. 'capsule run attach' to return.\n",
            ) catch {};
            return 0;
        }
    } else |_| {}

    return reportSessionEnd(ctx, container);
}

/// Removes this project's replica and run directories from the VM.
///
/// Two fixes over the shell version, both flagged in the plan. The container and directory
/// lists were interpolated unquoted and relied on word splitting, so an empty list turned
/// `rm -rf $dirs` into a bare `rm -rf`; here each name is quoted and an empty list means
/// the command is not built at all. And the replica name came from an unguarded `jq -r`,
/// so a missing field yielded the literal string `null`, which reached
/// `rm -rf ~/capsule/null`.
///
/// Returns false when the caller should stop.
fn resetVmSide(ctx: *Ctx, replica: []const u8, force: bool) bool {
    if (replica.len == 0) {
        return ctx.fail("the store has no replica name for this project — refusing to guess", .{}) == 0;
    }
    const p = ctx.repoParams();

    if (!force and !unmergedIsEmpty(ctx, replica)) return false;

    const runs = switch (api.call(ctx.arena, ctx.io, ctx.socket, api.gc_runs, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e}) == 0) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f) == 0,
    };

    var script: std.ArrayList(u8) = .empty;
    var alloc = Writer.Allocating.fromArrayList(ctx.arena, &script);
    const w = &alloc.writer;

    if (runs.len > 0) {
        w.writeAll("podman rm -f") catch return false;
        for (runs) |r| w.print(" {s}", .{ssh.shellQuote(ctx.arena, r.container) catch return false}) catch return false;
        w.writeAll(" >/dev/null 2>&1 || true\nrm -rf") catch return false;
        for (runs) |r| {
            w.print(" \"$HOME/.capsule/runs/\"{s}", .{
                ssh.shellQuote(ctx.arena, r.dir) catch return false,
            }) catch return false;
        }
        w.writeAll("\n") catch return false;
    }
    w.print("rm -rf \"$HOME/capsule/\"{s}\n", .{
        ssh.shellQuote(ctx.arena, replica) catch return false,
    }) catch return false;

    const out = ssh.run(ctx.arena, ctx.io, ctx.sshConfig(), alloc.written(), 120) catch |e|
        return ctx.fail("ssh failed: {t}", .{e}) == 0;
    if (!out.ok()) return ctx.fail("could not clean the VM: {s}", .{out.trimmedErr()}) == 0;

    ctx.out.print("removed replica {s} and {d} run dir(s) from the VM\n", .{ replica, runs.len }) catch {};
    return true;
}

/// Whether the replica holds no unmerged `capsule/*` branch.
///
/// A squash merge leaves the branch's commits out of the main branch's ancestry, so git
/// cannot answer "is this merged" — the issue states behind `gc.branches` are the only
/// signal there is.
fn unmergedIsEmpty(ctx: *Ctx, replica: []const u8) bool {
    const p = ctx.repoParams();

    const remote = std.fmt.allocPrint(
        ctx.arena,
        "repo=$HOME/capsule/{s}\n" ++
            "[ -d \"$repo/.git\" ] || exit 0\n" ++
            "git -C \"$repo\" for-each-ref --format='%(refname:short)' refs/heads/capsule/\n",
        .{ssh.shellQuote(ctx.arena, replica) catch return false},
    ) catch return false;

    const listed = ssh.run(ctx.arena, ctx.io, ctx.sshConfig(), remote, 60) catch |e|
        return ctx.fail("ssh failed: {t}", .{e}) == 0;
    if (!listed.ok()) return true;

    const merged = switch (api.call(ctx.arena, ctx.io, ctx.socket, api.gc_branches, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e}) == 0) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f) == 0,
    };

    var unmerged: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (lines.next()) |raw| {
        const branch = std.mem.trim(u8, raw, " \t\r");
        if (branch.len == 0) continue;
        var is_merged = false;
        for (merged) |m| {
            if (std.mem.eql(u8, m, branch)) is_merged = true;
        }
        if (!is_merged) unmerged.append(ctx.arena, branch) catch return false;
    }
    if (unmerged.items.len == 0) return true;

    ctx.err.writeAll("capsule: the replica still holds unmerged work:\n") catch {};
    for (unmerged.items) |b| ctx.err.print("  {s}\n", .{b}) catch {};
    _ = ctx.fail("'capsule run fetch' brings the branches here first; --force drops them", .{});
    return false;
}

/// Drops the `vm` remote, which takes `refs/remotes/vm/*` with it — so the replica's
/// branches leave no trace here either.
fn resetLocalSide(ctx: *Ctx) void {
    const g = git.Git{ .arena = ctx.arena, .io = ctx.io };
    if (!g.succeeds(&.{ "remote", "get-url", git.remote })) return;
    if (g.run(&.{ "remote", "remove", git.remote })) |_| {
        ctx.out.writeAll("removed the 'vm' remote and its tracking refs\n") catch {};
    } else |_| {}
}

fn hasForceFlag(ctx: *Ctx) bool {
    for (ctx.args) |a| {
        if (std.mem.eql(u8, a, "--force")) return true;
    }
    return false;
}

/// `run reset` — drop this project's replica, run dirs and `vm` remote.
fn runReset(ctx: *Ctx) u8 {
    const p = ctx.repoParams();
    const force = hasForceFlag(ctx);

    const project = switch (api.call(ctx.arena, ctx.io, ctx.socket, api.project_get, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e})) {
        .ok => |v| v,
        .err => return ctx.fail("not a registered project — nothing to reset", .{}),
    };

    if (liveContainer(ctx) != null) {
        return ctx.fail("a run is still live — 'capsule run end' first", .{});
    }

    if (!resetVmSide(ctx, project.replica, force)) return 1;
    resetLocalSide(ctx);
    ctx.out.writeAll(
        "the project is still registered — 'capsule run start' rebuilds from scratch\n",
    ) catch {};
    return 0;
}

/// `project rm` — unregister, after clearing the VM side.
///
/// The issue count is asked here as well as by the daemon, and deliberately: the remote
/// clean has to run first, because the store is what names the replica and the run
/// directories. A refusal arriving after the replica was already gone would be the worst
/// of both. The daemon still enforces it.
fn projectRm(ctx: *Ctx) u8 {
    const p = ctx.repoParams();
    const force = hasForceFlag(ctx);

    if (!force) {
        const issues = switch (api.call(ctx.arena, ctx.io, ctx.socket, api.issue_list, .{
            .git_common_dir = p.git_common_dir,
            .cwd = p.cwd,
            .state = null,
        }) catch |e| return ctx.fail("{t}", .{e})) {
            .ok => |v| v,
            .err => |f| return failure(ctx, f),
        };
        if (issues.len > 0) {
            return ctx.fail(
                "this project still has {d} issue(s) — pass --force to remove it anyway",
                .{issues.len},
            );
        }
    }

    const project = switch (api.call(ctx.arena, ctx.io, ctx.socket, api.project_get, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e})) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };

    // An unreachable VM costs only the remote half. Refusing would strand a project that
    // could then never be unregistered.
    if (vmReachable(ctx)) {
        if (!resetVmSide(ctx, project.replica, force)) return 1;
    } else {
        ctx.err.print(
            "capsule: VM unreachable — replica {s} and its run dirs left in place\n",
            .{project.replica},
        ) catch {};
    }
    resetLocalSide(ctx);

    const removed = api.call(ctx.arena, ctx.io, ctx.socket, api.project_rm, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .force = force,
    }) catch |e| return ctx.fail("{t}", .{e});
    switch (removed) {
        .ok => ctx.out.writeAll("unregistered\n") catch {},
        .err => |f| return failure(ctx, f),
    }
    return 0;
}

/// `run end` — end the live run and remove its container.
///
/// The store is told first and the container tidied only if the VM answers. That order is
/// deliberate: a run gets stuck precisely when the VM is unreachable, so requiring the VM
/// here would break the command in the one case it exists for.
fn runEnd(ctx: *Ctx) u8 {
    const container = liveContainer(ctx) orelse
        return ctx.fail("no run is live on this project", .{});

    const p = ctx.repoParams();
    const ended = api.call(ctx.arena, ctx.io, ctx.socket, api.run_end, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch |e| return ctx.fail("{t}", .{e});
    switch (ended) {
        .ok => {},
        .err => |f| return failure(ctx, f),
    }

    if (vmReachable(ctx)) {
        const remote = std.fmt.allocPrint(ctx.arena, "podman rm -f {s}", .{
            ssh.shellQuote(ctx.arena, container) catch return 1,
        }) catch return 1;
        _ = ssh.run(ctx.arena, ctx.io, ctx.sshConfig(), remote, 60) catch {};
    } else {
        ctx.err.print("capsule: VM unreachable — container {s} left as it is\n", .{container}) catch {};
    }

    ctx.out.writeAll(
        "run ended. The issue keeps its state — 'capsule issue state <id> open' to reset it.\n",
    ) catch {};
    return 0;
}

/// `run review` — read the agent's branch, and hand your comments back to the issue.
///
/// Without `tuicr`, or with stdout redirected, this degrades to `git log -p`. That is not
/// a fallback for missing software so much as the scripted form of the same question.
fn runReview(ctx: *Ctx) u8 {
    const id = issueTarget(ctx, if (ctx.args.len > 0) ctx.args[0] else null, ready_only) orelse return 1;
    const p = ctx.repoParams();
    const g = git.Git{ .arena = ctx.arena, .io = ctx.io };

    const got = api.call(ctx.arena, ctx.io, ctx.socket, api.issue_get, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = id,
    }) catch |e| return ctx.fail("{t}", .{e});
    const issue = switch (got) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };

    const fetched = git.fetch(g) catch |e| return ctx.fail("could not fetch from the replica: {t}", .{e});
    if (!fetched.ok()) return ctx.fail("could not fetch from the replica: {s}", .{fetched.trimmedErr()});

    const branch = git.issueBranch(ctx.arena, issue.id) catch return 1;
    const remote_ref = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ git.remote, branch }) catch return 1;
    if (!git.hasRef(g, remote_ref)) {
        return ctx.fail("the replica has no {s} — has this issue been dispatched?", .{branch});
    }
    const range = std.fmt.allocPrint(ctx.arena, "HEAD..{s}", .{remote_ref}) catch return 1;

    const on_tty = Io.File.stdout().isTty(ctx.io) catch false;
    if (!on_tty or !exec.present(ctx.arena, ctx.io, "tuicr")) {
        const code = handStream(ctx, &.{ "git", "log", "-p", "--reverse", range }) catch |e|
            return ctx.fail("{t}", .{e});
        return code;
    }

    const review = handCapture(ctx, &.{
        "tuicr", "--no-update-check", "--stdout", "-r", range,
    }) catch |e| return ctx.fail("tuicr failed: {t}", .{e});

    const exported = std.mem.trim(u8, review.stdout, " \t\r\n");
    if (exported.len == 0) {
        ctx.out.writeAll("no comments exported — press y in tuicr to hand them back to the issue\n") catch {};
        return 0;
    }

    ctx.out.print("{s}\n\n", .{exported}) catch {};
    if (!confirm(ctx, "attach to the issue for the agent's next run?")) {
        ctx.out.writeAll("not attached\n") catch {};
        return 0;
    }

    const commented = api.call(ctx.arena, ctx.io, ctx.socket, api.issue_comment, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .id = issue.id,
        .text = exported,
    }) catch |e| return ctx.fail("{t}", .{e});
    switch (commented) {
        .ok => ctx.out.writeAll("attached\n") catch {},
        .err => |f| return failure(ctx, f),
    }
    return 0;
}

/// The container of this project's live run, if there is one.
fn liveContainer(ctx: *Ctx) ?[]const u8 {
    const p = ctx.repoParams();
    const listed = api.call(ctx.arena, ctx.io, ctx.socket, api.run_list, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch return null;

    return switch (listed) {
        .ok => |runs| for (runs) |r| {
            if (r.state == .active) break r.container;
        } else null,
        .err => null,
    };
}

/// What the agent left behind on its way out.
///
/// The container stops itself once the agent exits and `handoff.sh` commits whatever was
/// still uncommitted. Its report was printed to a terminal that no longer exists by the
/// time ssh returns, so it is read back from the run's state directory instead.
fn reportSessionEnd(ctx: *Ctx, container: []const u8) u8 {
    const p = ctx.repoParams();

    // The daemon's poller marks a vanished container's run abandoned within seconds, and
    // quitting the agent is a clean end rather than something breaking. Whichever call
    // lands first wins; both revoke the token, so losing the race costs only a word.
    _ = api.call(ctx.arena, ctx.io, ctx.socket, api.run_end, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
    }) catch {};

    // Both names are cut from the same 12 hex characters of the run id, so one recovers
    // the other: `capsule-<12>` in the store, `runs/<12>` in the run directory.
    const prefix = "capsule-";
    const dir = if (std.mem.startsWith(u8, container, prefix)) container[prefix.len..] else container;
    // Assigned first, then used as `"$log"`: a shell-quoted value written straight into
    // `"..."` is not quoted at all, it just gains apostrophes.
    const remote = std.fmt.allocPrint(
        ctx.arena,
        "log=$HOME/.capsule/runs/{s}/claude/handoff.log; cat \"$log\" 2>/dev/null || true",
        .{ssh.shellQuote(ctx.arena, dir) catch return 1},
    ) catch return 1;

    if (ssh.run(ctx.arena, ctx.io, ctx.sshConfig(), remote, 30)) |out| {
        if (out.stdout.len > 0) ctx.out.print("{s}\n", .{out.trimmed()}) catch {};
    } else |_| {}

    ctx.out.writeAll(
        "capsule: the session ended and the container stopped.\n" ++
            "         'capsule run merge' to bring the work over, 'capsule run start' to resume.\n",
    ) catch {};
    return 0;
}

/// Writes the agent-state tree and the env file into a fresh temp directory, and hands
/// back its path.
///
/// The env file lives here rather than travelling on its own ssh connection, so the run
/// token and the agent's credentials are never an argument to anything. It is created
/// 0600 before a byte goes into it.
fn buildSeed(
    ctx: *Ctx,
    started: api.RunStart,
    profile: []const u8,
    project_dir: []const u8,
) ?[]const u8 {
    const tmp = ctx.environ.get("TMPDIR") orelse "/tmp";
    const dir = std.fmt.allocPrint(ctx.arena, "{s}/capsule-seed-{s}", .{
        std.mem.trimEnd(u8, tmp, "/"),
        started.run[0..@min(12, started.run.len)],
    }) catch return null;

    const cwd = Io.Dir.cwd();
    cwd.deleteTree(ctx.io, dir) catch {};
    cwd.createDirPath(ctx.io, dir) catch {
        _ = ctx.fail("cannot create {s}", .{dir});
        return null;
    };

    const template_path = std.fmt.allocPrint(ctx.arena, "{s}/capsule/agent-settings.json", .{
        ctx.environ.get("XDG_CONFIG_HOME") orelse
            std.fmt.allocPrint(ctx.arena, "{s}/.config", .{ctx.environ.get("HOME") orelse "/root"}) catch return null,
    }) catch return null;
    const user_template = cwd.readFileAlloc(ctx.io, template_path, ctx.arena, .limited(1 << 20)) catch "";

    const claude_dir = std.fmt.allocPrint(ctx.arena, "{s}/claude", .{dir}) catch return null;

    seed_mod.writeTree(ctx.arena, ctx.io, claude_dir, user_template, .{
        .issue_short = shortId(started.issue),
        .issue_title = started.title,
        .project_dir = project_dir,
        .mcp_port = ctx.settings.mcp_port,
        .theme = project_mod.profilePref(ctx.arena, ctx.io, ctx.environ, profile, "theme", "dark"),
        .editor_mode = project_mod.profilePref(ctx.arena, ctx.io, ctx.environ, profile, "editor-mode", "vim"),
    }) catch |e| {
        _ = ctx.fail("could not build the agent-state tree: {t}", .{e});
        return null;
    };

    const oauth = project_mod.profilePref(ctx.arena, ctx.io, ctx.environ, profile, "token", "");
    const contents = run_mod.envFileContents(ctx.arena, started.token, oauth) catch return null;
    if (!writeSecret(ctx, std.fmt.allocPrint(ctx.arena, "{s}/env", .{dir}) catch return null, contents)) {
        return null;
    }
    return dir;
}

/// Writes a file that must not be readable by anyone else, creating it 0600 rather than
/// creating it wide and narrowing afterwards.
fn writeSecret(ctx: *Ctx, path: []const u8, contents: []const u8) bool {
    var file = Io.Dir.cwd().createFile(ctx.io, path, .{
        .permissions = @enumFromInt(0o600),
    }) catch {
        _ = ctx.fail("cannot write {s}", .{path});
        return false;
    };
    defer file.close(ctx.io);

    var buf: [1024]u8 = undefined;
    var w = file.writer(ctx.io, &buf);
    w.interface.writeAll(contents) catch {
        _ = ctx.fail("cannot write {s}", .{path});
        return false;
    };
    w.interface.flush() catch {
        _ = ctx.fail("cannot write {s}", .{path});
        return false;
    };
    return true;
}

/// Tars the seed tree to a file beside it, and hands back the open file.
///
/// A file rather than a pipe: it becomes the ssh child's stdin directly, so nothing on
/// this side can block waiting on a buffer the far side has not drained.
fn packSeed(ctx: *Ctx, seed_dir: []const u8) ?Io.File {
    const path = std.fmt.allocPrint(ctx.arena, "{s}.tgz", .{seed_dir}) catch return null;

    const out = exec.run(ctx.arena, ctx.io, &.{
        "tar", "czf", path, "-C", seed_dir, "claude", "env",
    }, .{ .environ = ctx.environ }) catch |e| {
        _ = ctx.fail("could not pack the seed: {t}", .{e});
        return null;
    };
    if (!out.ok()) {
        _ = ctx.fail("could not pack the seed: {s}", .{out.trimmedErr()});
        return null;
    }

    return Io.Dir.cwd().openFile(ctx.io, path, .{}) catch {
        _ = ctx.fail("could not read the packed seed", .{});
        return null;
    };
}

/// The first remote script: replica, no-remotes check, seed extraction, git identity.
fn bootstrapVm(ctx: *Ctx, replica: []const u8, run_dir: []const u8) ?run_mod.Bootstrap {
    const g = git.Git{ .arena = ctx.arena, .io = ctx.io };

    const script = run_mod.bootstrapScript(ctx.arena, .{
        .replica = replica,
        .run_dir = run_dir,
        .git_name = g.capture(&.{ "config", "--get", "user.name" }) catch "",
        .git_email = g.capture(&.{ "config", "--get", "user.email" }) catch "",
    }) catch return null;

    const out = ssh.run(ctx.arena, ctx.io, ctx.sshConfig(), script, 120) catch |e| {
        _ = ctx.fail("ssh failed: {t}", .{e});
        return null;
    };
    const boot = run_mod.parseBootstrap(out.stdout);

    if (out.code == run_mod.replica_has_remotes) {
        _ = ctx.fail(
            "replica ~/capsule/{s} has git remotes ({s}) — agent commits could escape; refusing",
            .{ replica, boot.remotes },
        );
        return null;
    }
    if (!out.ok()) {
        _ = ctx.fail("could not prepare the VM (exit {d})", .{out.code});
        return null;
    }
    if (boot.home.len == 0) {
        _ = ctx.fail("the VM did not report a home directory", .{});
        return null;
    }
    if (boot.bootstrapped) {
        ctx.out.print("bootstrapped {s} in the VM\n", .{replica}) catch {};
    }
    return boot;
}

/// Points the `vm` remote at the replica and pushes the issue's branch onto it.
fn pushToReplica(ctx: *Ctx, g: git.Git, replica: []const u8, branch: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, ctx.settings.vm_host, '@') orelse 0;
    const user = ctx.settings.vm_host[0..at];
    const url = std.fmt.allocPrint(ctx.arena, "ssh://{s}:{d}/home/{s}/capsule/{s}", .{
        ctx.settings.vm_host, ctx.settings.vm_port, user, replica,
    }) catch return false;

    if (!g.succeeds(&.{ "remote", "get-url", git.remote })) {
        _ = g.run(&.{ "remote", "add", git.remote, url }) catch {};
    }
    _ = g.run(&.{ "remote", "set-url", git.remote, url }) catch {};

    const refspec = std.fmt.allocPrint(ctx.arena, "HEAD:{s}", .{branch}) catch return false;
    const pushed = g.run(&.{ "push", "-q", git.remote, refspec }) catch |e| {
        _ = ctx.fail("could not push {s} to the replica: {t}", .{ branch, e });
        return false;
    };
    if (!pushed.ok()) {
        _ = ctx.fail("could not push {s} to the replica: {s}", .{ branch, pushed.trimmedErr() });
        return false;
    }
    return true;
}

/// Removes the local seed tree and its tarball. Both held the run token.
fn removeSeed(ctx: *Ctx, dir: []const u8) void {
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(ctx.io, dir) catch {};
    if (std.fmt.allocPrint(ctx.arena, "{s}.tgz", .{dir})) |tgz| {
        cwd.deleteFile(ctx.io, tgz) catch {};
    } else |_| {}
}

/// `vm status` — where the agent host is, and whether it is up.
///
/// Reads the daemon's world model instead of re-ssh'ing `uptime -p` the way bash did.
/// The daemon has polled that fact within the last few seconds; asking again over the
/// network for something already in memory is what made the old `vm status` slow.
fn vmStatus(ctx: *Ctx) u8 {
    const kind: []const u8 = if (isLocalVm(ctx.settings.vm_host)) "local qemu" else "remote";
    ctx.out.print("host    {s}:{d} ({s})\n", .{ ctx.settings.vm_host, ctx.settings.vm_port, kind }) catch {};

    const world = api.call(ctx.arena, ctx.io, ctx.socket, api.world_get, .{}) catch {
        // No daemon, so there is no model to read and the only honest answer is a probe.
        const up = ssh.reachable(ctx.arena, ctx.io, ctx.sshConfig());
        ctx.out.print("state   {s}\n", .{if (up) "up" else "unreachable"}) catch {};
        ctx.out.writeAll("uptime  unknown — capsuled is not running\n") catch {};
        return 0;
    };

    switch (world) {
        .ok => |w| {
            if (!w.reachable) {
                ctx.out.writeAll("state   unreachable\n") catch {};
                return 0;
            }
            ctx.out.writeAll("state   up\n") catch {};
            if (w.uptime_s) |up| {
                ctx.out.print("uptime  {d}h {d}m\n", .{ up / 3600, (up % 3600) / 60 }) catch {};
            }
            if (w.disk_used) |used| {
                const total = w.disk_total orelse 0;
                const pct: u64 = if (total > 0) used * 100 / total else 0;
                ctx.out.print("disk    {d} GB of {d} GB ({d}%)\n", .{
                    used / (1 << 30), total / (1 << 30), pct,
                }) catch {};
            }
            if (w.containers.len > 0) {
                ctx.out.print("running {d} container(s)\n", .{w.containers.len}) catch {};
            }
        },
        .err => ctx.out.writeAll("state   unknown\n") catch {},
    }
    return 0;
}

/// A single-keystroke y/N question, asked on the terminal.
///
/// `/dev/tty` rather than stdin, the way `editor.zig` opens it: capsule's stdin is
/// frequently not a terminal — the CLI gets run from command substitution — and a
/// destructive command must not read its confirmation from a pipe. No terminal means no,
/// which is the only safe default for the commands that ask.
fn confirm(ctx: *Ctx, question: []const u8) bool {
    ctx.flush();
    const tty = Io.Dir.cwd().openFile(ctx.io, "/dev/tty", .{ .mode = .read_write }) catch {
        _ = ctx.fail("not a terminal — refusing to assume yes", .{});
        return false;
    };
    defer tty.close(ctx.io);

    var out_buf: [64]u8 = undefined;
    var w = tty.writer(ctx.io, &out_buf);
    w.interface.print("{s} [y/N] ", .{question}) catch return false;
    w.interface.flush() catch return false;

    var in_buf: [8]u8 = undefined;
    var r = tty.readerStreaming(ctx.io, &in_buf);
    const answer = r.interface.takeByte() catch return false;

    var nl_buf: [4]u8 = undefined;
    var nl = tty.writer(ctx.io, &nl_buf);
    nl.interface.writeAll("\n") catch {};
    nl.interface.flush() catch {};

    return answer == 'y' or answer == 'Y';
}

/// Reads one line from the terminal without echoing it.
///
/// Only `ECHO` is cleared — not the full raw mode `tui/term.zig` enters. Canonical mode
/// stays on, so the terminal still does line editing and still hands the line over on
/// enter; a pasted token needs backspace to work, and reimplementing that would be the
/// only reason to take raw mode. Restored on every path, including the read failing.
fn readSecret(ctx: *Ctx, prompt: []const u8) ?[]const u8 {
    ctx.flush();
    const tty = Io.Dir.cwd().openFile(ctx.io, "/dev/tty", .{ .mode = .read_write }) catch {
        _ = ctx.fail("not a terminal — nothing to read a token from", .{});
        return null;
    };
    defer tty.close(ctx.io);

    var out_buf: [128]u8 = undefined;
    var w = tty.writer(ctx.io, &out_buf);
    w.interface.writeAll(prompt) catch return null;
    w.interface.flush() catch return null;

    const fd = tty.handle;
    const original = std.posix.tcgetattr(fd) catch {
        _ = ctx.fail("cannot control terminal echo", .{});
        return null;
    };
    var quiet = original;
    quiet.lflag.ECHO = false;
    std.posix.tcsetattr(fd, .FLUSH, quiet) catch {
        _ = ctx.fail("cannot turn terminal echo off — refusing to read a token in the clear", .{});
        return null;
    };
    defer {
        std.posix.tcsetattr(fd, .FLUSH, original) catch {};
        var nl_buf: [4]u8 = undefined;
        var nl = tty.writer(ctx.io, &nl_buf);
        nl.interface.writeAll("\n") catch {};
        nl.interface.flush() catch {};
    }

    var in_buf: [4096]u8 = undefined;
    var r = tty.readerStreaming(ctx.io, &in_buf);
    const line = r.interface.takeDelimiter('\n') catch return null;
    const text = line orelse return null;
    return ctx.arena.dupe(u8, std.mem.trim(u8, text, " \t\r")) catch null;
}

/// `login` — a container to authenticate the agent CLI in.
///
/// The token is stored on this machine and injected per run; it is never written into the
/// container's filesystem. `project.validProfile` is applied rather than bash's weaker
/// regex — same character set, but with the 64-character cap bash left off.
fn login(ctx: *Ctx) u8 {
    const profile = if (ctx.args.len > 0) ctx.args[0] else "default";
    if (!project_mod.validProfile(profile)) {
        return ctx.fail("invalid profile '{s}' (use [A-Za-z0-9_-], max 64)", .{profile});
    }

    const cfg = ctx.sshConfig();
    const quoted_profile = ssh.shellQuote(ctx.arena, profile) catch return 1;

    // The same round trip creates the directory and reports `$HOME`, because the mount
    // podman is given has to be an absolute path — see `run.LoginConfig.state_dir`.
    const prepare = std.fmt.allocPrint(
        ctx.arena,
        "set -e\ndir=$HOME/.capsule/profiles/{s}/claude\nmkdir -p \"$dir\"\nprintf 'home\\t%s\\n' \"$dir\"\n",
        .{quoted_profile},
    ) catch return 1;
    const made = ssh.run(ctx.arena, ctx.io, cfg, prepare, 60) catch |e|
        return ctx.fail("ssh failed: {t}", .{e});
    if (!made.ok()) return ctx.fail("could not prepare the profile on the VM: {s}", .{made.trimmedErr()});

    const state_dir = run_mod.parseBootstrap(made.stdout).home;
    if (state_dir.len == 0) return ctx.fail("the VM did not report the profile directory", .{});

    ctx.out.print(
        \\
        \\  capsule login — profile '{s}'
        \\
        \\  In the container, run:
        \\
        \\      claude setup-token
        \\
        \\  and follow the prompts. Copy the token it prints, then exit (ctrl-d), and paste it
        \\  when asked. capsule stores it on this machine and injects it per run; it is never
        \\  written into the container's filesystem.
        \\
        \\
    , .{profile}) catch {};

    const container = run_mod.commandLine(ctx.arena, run_mod.loginArgs(ctx.arena, .{
        .image = ctx.settings.image,
        .container_home = ctx.settings.container_home,
        .profile = profile,
        .state_dir = state_dir,
    }) catch return 1) catch return 1;

    _ = handSshInteractive(ctx, container) catch |e|
        return ctx.fail("ssh failed: {t}", .{e});

    const store = project_mod.profileDir(ctx.arena, ctx.environ, profile) catch
        return ctx.fail("cannot work out where to store the token", .{});
    Io.Dir.cwd().createDirPath(ctx.io, store) catch
        return ctx.fail("cannot create {s}", .{store});

    // Seeded once and then left alone: editing these is how a profile's runs get a
    // different theme or editor mode, so a later login must not overwrite the choice.
    for ([_][2][]const u8{ .{ "theme", "dark\n" }, .{ "editor-mode", "vim\n" } }) |pref| {
        const path = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ store, pref[0] }) catch return 1;
        if (!exists(ctx, path)) {
            if (!writeSecret(ctx, path, pref[1])) return 1;
        }
    }

    const token = readSecret(ctx, "paste the token (input hidden), or press enter to skip: ") orelse
        return 1;
    if (token.len == 0) {
        ctx.out.writeAll("no token stored\n") catch {};
        return 0;
    }

    const path = std.fmt.allocPrint(ctx.arena, "{s}/token", .{store}) catch return 1;
    const contents = std.fmt.allocPrint(ctx.arena, "{s}\n", .{token}) catch return 1;
    if (!writeSecret(ctx, path, contents)) return 1;

    ctx.out.print("token stored for profile '{s}'\n", .{profile}) catch {};
    return 0;
}

/// `vm start` — boot the local qemu VM, downloading the disk the first time.
///
/// Runs in the foreground for as long as the VM does: `-nographic` puts the guest console
/// on this terminal, which is what bash's trailing `exec` arranged.
fn vmStart(ctx: *Ctx) u8 {
    if (builtin.cpu.arch != .aarch64) {
        return ctx.fail(
            "'vm start' only supports aarch64 hosts — point CAPSULE_VM_HOST at a real machine instead",
            .{},
        );
    }

    const key = Io.Dir.cwd().readFileAlloc(ctx.io, ctx.settings.ssh_key, ctx.arena, .limited(1 << 16)) catch
        return ctx.fail("no ssh public key at {s} (set CAPSULE_SSH_KEY)", .{ctx.settings.ssh_key});

    Io.Dir.cwd().createDirPath(ctx.io, ctx.settings.data_dir) catch
        return ctx.fail("cannot create {s}", .{ctx.settings.data_dir});

    const disk = std.fmt.allocPrint(ctx.arena, "{s}/fcos.qcow2", .{ctx.settings.data_dir}) catch return 1;
    if (!exists(ctx, disk)) {
        if (fetchDisk(ctx, disk)) |code| return code;
    }

    const ignition = writeIgnition(ctx, key) orelse return 1;

    const qemu = whichQemu(ctx) orelse return 1;
    const firmware = vm.firmwarePath(ctx.arena, qemu) catch
        return ctx.fail("could not locate the UEFI firmware next to {s}", .{qemu});
    if (!exists(ctx, firmware)) {
        return ctx.fail("UEFI firmware not found at {s}", .{firmware});
    }

    ctx.out.print("booting VM ({d} cpu, {d}M, ssh on :{d})\n", .{
        ctx.settings.vm_cpus, ctx.settings.vm_mem, ctx.settings.vm_port,
    }) catch {};

    const argv = vm.qemuArgs(ctx.arena, .{
        .vm_host = ctx.settings.vm_host,
        .vm_port = ctx.settings.vm_port,
        .vm_cpus = ctx.settings.vm_cpus,
        .vm_mem = ctx.settings.vm_mem,
        .disk = disk,
        .ignition = ignition,
        .firmware = firmware,
        .qemu = qemu,
    }) catch return 1;

    return handInteractive(ctx, argv) catch |e| ctx.fail("qemu failed: {t}", .{e});
}

/// Downloads, verifies and decompresses the Fedora CoreOS disk. Returns a non-null exit
/// code only on failure.
///
/// `curl` and `xz` stay as processes — reimplementing a resumable downloader is the least
/// valuable code that could be written here. The checksum does not: a wrong disk that
/// boots is worse than one that fails to.
fn fetchDisk(ctx: *Ctx, disk: []const u8) ?u8 {
    forgetHostKey(ctx);
    ctx.out.print("no disk yet, fetching Fedora CoreOS ({s}, aarch64)\n", .{ctx.settings.stream}) catch {};

    const meta_url = vm.streamUrl(ctx.arena, ctx.settings.stream) catch return 1;
    const meta = exec.run(ctx.arena, ctx.io, &.{ "curl", "-fsSL", meta_url }, .{}) catch |e|
        return ctx.fail("could not fetch the stream metadata: {t}", .{e});
    if (!meta.ok()) return ctx.fail("could not fetch {s}", .{meta_url});

    const artifact = vm.parseStream(ctx.arena, meta.stdout) catch |e|
        return ctx.fail("could not read the stream metadata: {t}", .{e});

    const xz_path = std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{
        ctx.settings.data_dir, artifact.filename(),
    }) catch return 1;

    const fetched = handStream(ctx, &.{
        "curl", "-fL", "-C", "-", "-o", xz_path, artifact.location,
    }) catch |e| return ctx.fail("download failed: {t}", .{e});
    if (fetched != 0) return ctx.fail("download failed", .{});

    ctx.out.writeAll("verifying checksum\n") catch {};
    const got = vm.sha256File(ctx.arena, ctx.io, xz_path) catch |e|
        return ctx.fail("could not hash {s}: {t}", .{ xz_path, e });
    if (!vm.digestsMatch(got, artifact.sha256)) {
        return ctx.fail(
            "checksum mismatch on {s}\n  expected {s}\n  got      {s}",
            .{ xz_path, artifact.sha256, got },
        );
    }

    // `unxz` writes alongside its input, dropping the suffix — no stdout redirection, so
    // no shell. The result is then renamed into place.
    //
    // The suffix is removed by length, not by `trimEnd`: that takes a *set* of bytes, so
    // it would keep eating any trailing `.`, `x` or `z` beyond the one suffix.
    const suffix = ".xz";
    if (!std.mem.endsWith(u8, xz_path, suffix)) return ctx.fail("unexpected download name {s}", .{xz_path});
    const decompressed = xz_path[0 .. xz_path.len - suffix.len];
    const unxz = handStream(ctx, &.{ "unxz", "-f", xz_path }) catch |e|
        return ctx.fail("could not decompress {s}: {t}", .{ xz_path, e });
    if (unxz != 0) return ctx.fail("could not decompress {s}", .{xz_path});

    Io.Dir.cwd().rename(decompressed, Io.Dir.cwd(), disk, ctx.io) catch
        return ctx.fail("could not move {s} into place", .{decompressed});

    const resized = exec.run(ctx.arena, ctx.io, &.{
        "qemu-img", "resize", disk, ctx.settings.disk_size,
    }, .{}) catch |e| return ctx.fail("qemu-img resize failed: {t}", .{e});
    if (!resized.ok()) return ctx.fail("qemu-img resize failed: {s}", .{resized.trimmedErr()});

    return null;
}

/// Renders the butane template with the user's key and compiles it to ignition.
fn writeIgnition(ctx: *Ctx, ssh_key: []const u8) ?[]const u8 {
    // The shipped template is compiled in; `CAPSULE_BUTANE` names a different one for
    // anyone provisioning the VM their own way.
    const butane_src = if (ctx.environ.get("CAPSULE_BUTANE")) |path|
        Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1 << 20)) catch {
            _ = ctx.fail("no butane template at {s} (CAPSULE_BUTANE)", .{path});
            return null;
        }
    else
        vm.butane_template;

    const source = vm.renderIgnitionSource(ctx.arena, butane_src, ssh_key) catch |e| {
        _ = ctx.fail("cannot use the ssh key at {s}: {t}", .{ ctx.settings.ssh_key, e });
        return null;
    };

    const source_path = std.fmt.allocPrint(ctx.arena, "{s}/fcos.bu", .{ctx.settings.data_dir}) catch return null;
    if (!writeSecret(ctx, source_path, source)) return null;

    // butane takes its input as a file argument, so there is nothing to pipe and no shell
    // to pipe it with — bash needed `sed ... | butane --strict > ign`.
    const built = exec.run(ctx.arena, ctx.io, &.{ "butane", "--strict", source_path }, .{}) catch |e| {
        _ = ctx.fail("butane failed: {t}", .{e});
        return null;
    };
    if (!built.ok()) {
        _ = ctx.fail("butane rejected the config: {s}", .{built.trimmedErr()});
        return null;
    }

    const ignition = std.fmt.allocPrint(ctx.arena, "{s}/fcos.ign", .{ctx.settings.data_dir}) catch return null;
    if (!writeSecret(ctx, ignition, built.stdout)) return null;
    return ignition;
}

/// The qemu binary, resolved through any symlinks so the firmware can be found beside it.
fn whichQemu(ctx: *Ctx) ?[]const u8 {
    const found = exec.run(ctx.arena, ctx.io, &.{
        "sh", "-c", "command -v \"$1\"", "sh", "qemu-system-aarch64",
    }, .{}) catch |e| {
        _ = ctx.fail("could not look for qemu: {t}", .{e});
        return null;
    };
    if (!found.ok() or found.trimmed().len == 0) {
        _ = ctx.fail("qemu-system-aarch64 not found", .{});
        return null;
    }
    return git.realpath(ctx.arena, ctx.io, found.trimmed()) catch found.trimmed();
}

/// Drops the VM's recorded host key, so a rebuilt disk does not read as an attack.
fn forgetHostKey(ctx: *Ctx) void {
    const entry = vm.knownHostsEntry(ctx.arena, ctx.settings.vm_host, ctx.settings.vm_port) catch return;
    _ = exec.run(ctx.arena, ctx.io, &.{ "ssh-keygen", "-R", entry }, .{}) catch {};
}

/// `vm stop` — power it off from the inside, then drop the shared master.
fn vmStop(ctx: *Ctx) u8 {
    const cfg = ctx.sshConfig();
    _ = ssh.run(ctx.arena, ctx.io, cfg, "sudo poweroff", 30) catch {};
    closeMaster(ctx);
    ctx.out.writeAll("VM shutting down\n") catch {};
    return 0;
}

/// Tears down the shared ControlMaster, which otherwise holds a connection to a machine
/// that is going away.
fn closeMaster(ctx: *Ctx) void {
    const argv = ssh.controlArgs(ctx.arena, ctx.sshConfig(), "exit") catch return;
    _ = exec.run(ctx.arena, ctx.io, argv, .{}) catch {};
}

/// `vm disk` — what the disk actually costs, against what it claims.
fn vmDisk(ctx: *Ctx) u8 {
    const disk = std.fmt.allocPrint(ctx.arena, "{s}/fcos.qcow2", .{ctx.settings.data_dir}) catch return 1;
    if (!exists(ctx, disk)) {
        return ctx.fail("no VM disk at {s} — 'capsule vm start' first", .{disk});
    }
    if (vmReachable(ctx)) {
        ctx.err.writeAll("capsule: VM is running — sizes may lag slightly\n") catch {};
    }

    const info = exec.run(ctx.arena, ctx.io, &.{ "qemu-img", "info", "-U", disk }, .{}) catch |e|
        return ctx.fail("qemu-img info failed: {t}", .{e});
    if (!info.ok()) return ctx.fail("qemu-img info failed: {s}", .{info.trimmedErr()});

    // Each field once. `qemu-img info` repeats "disk size" in its child-node section, so
    // bash's `grep -E` printed the same number twice — the same file, reported twice.
    var seen_virtual = false;
    var seen_disk = false;
    var lines = std.mem.splitScalar(u8, info.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!seen_virtual and std.mem.startsWith(u8, trimmed, "virtual size")) {
            seen_virtual = true;
            ctx.out.print("{s}\n", .{trimmed}) catch {};
        }
        if (!seen_disk and std.mem.startsWith(u8, trimmed, "disk size")) {
            seen_disk = true;
            ctx.out.print("{s}\n", .{trimmed}) catch {};
        }
    }
    return 0;
}

/// `vm destroy` — delete the disk, after saying exactly what goes with it.
fn vmDestroy(ctx: *Ctx) u8 {
    const disk = std.fmt.allocPrint(ctx.arena, "{s}/fcos.qcow2", .{ctx.settings.data_dir}) catch return 1;
    if (!exists(ctx, disk)) return ctx.fail("no VM disk at {s}", .{disk});

    ctx.out.print(
        "this deletes the VM disk at {s}\n" ++
            "gone with it: the container image, every project replica, and all agent logins\n" ++
            "(your projects on this machine are untouched)\n",
        .{disk},
    ) catch {};

    if (!confirm(ctx, "destroy?")) {
        ctx.out.writeAll("aborted\n") catch {};
        return 1;
    }

    Io.Dir.cwd().deleteFile(ctx.io, disk) catch
        return ctx.fail("could not delete {s}", .{disk});
    for ([_][]const u8{ "fcos.ign", "fcos.bu" }) |name| {
        if (std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ ctx.settings.data_dir, name })) |path| {
            Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
        } else |_| {}
    }

    closeMaster(ctx);
    forgetHostKey(ctx);
    ctx.out.writeAll("destroyed — 'capsule vm start' builds a fresh one\n") catch {};
    return 0;
}

/// `vm ssh [cmd...]` — a login shell on the VM, or one command run there.
///
/// The arguments are joined and handed to the remote shell unquoted, which is what plain
/// `ssh host "$@"` does and what bash did. It is the one command where that is right: this
/// is the escape hatch, so `capsule vm ssh 'ls ~/capsule'` has to expand the tilde *there*.
/// Quoting each argument — which an earlier version of this did — makes the whole thing one
/// literal word and breaks exactly the use the command exists for.
///
/// Everywhere else the opposite holds: a value capsule constructs goes through
/// `ssh.shellQuote`, because there the remote shell re-parsing it is the hazard.
fn vmSsh(ctx: *Ctx) u8 {
    if (ctx.args.len == 0) {
        const code = handSshInteractive(ctx, "") catch |e|
            return ctx.fail("ssh failed: {t}", .{e});
        return code;
    }

    const remote = std.mem.join(ctx.arena, " ", ctx.args) catch return 1;
    const code = handSshStream(ctx, remote) catch |e|
        return ctx.fail("ssh failed: {t}", .{e});
    return code;
}

/// `image pull` — pull the published image, dropping the stale nix volume first.
///
/// The volume holds a nix store built against the old image; keeping it across a pull is
/// what produces a container whose `/nix` disagrees with its own binaries.
fn imagePull(ctx: *Ctx) u8 {
    const cfg = ctx.sshConfig();
    ssh.ensureMaster(ctx.arena, ctx.io, cfg);

    if (dropNixVolume(ctx)) |code| return code;

    const remote = std.fmt.allocPrint(ctx.arena, "podman pull {s} && podman image prune -f", .{
        ssh.shellQuote(ctx.arena, ctx.settings.image) catch return 1,
    }) catch return 1;

    const code = handSshStream(ctx, remote) catch |e|
        return ctx.fail("ssh failed: {t}", .{e});
    if (code != 0) return ctx.fail("podman pull failed", .{});
    return 0;
}

/// `image build` — build the image on the VM from this checkout instead of pulling it.
///
/// One ssh round trip carrying the source tarball on stdin, where bash made four: remove,
/// mkdir, extract, build. The tarball is capsule's own source, not the user's project —
/// `CAPSULE_SRC` names it, as it did in bash, falling back to the working directory.
///
/// TODO(phase-7): the tar still ships `bin/`, which is `bin/capsule`. When that is deleted
/// this sends the cross-compiled binary instead, and `container/Dockerfile:20` changes
/// with it.
fn imageBuild(ctx: *Ctx) u8 {
    const src = ctx.environ.get("CAPSULE_SRC") orelse
        (git.realpath(ctx.arena, ctx.io, ".") catch return ctx.fail("cannot resolve the working directory", .{}));

    const container_dir = std.fmt.allocPrint(ctx.arena, "{s}/container", .{src}) catch return 1;
    if (!exists(ctx, container_dir)) {
        return ctx.fail("container/ not found under {s} — set CAPSULE_SRC to capsule's checkout", .{src});
    }

    const cfg = ctx.sshConfig();
    ssh.ensureMaster(ctx.arena, ctx.io, cfg);
    if (dropNixVolume(ctx)) |code| return code;

    const tarball = packSource(ctx, src) orelse return 1;
    defer tarball.close(ctx.io);

    const script = std.fmt.allocPrint(
        ctx.arena,
        "set -e\n" ++
            "dir=$HOME/capsule-src\n" ++
            "rm -rf \"$dir\"\n" ++
            "mkdir -p \"$dir\"\n" ++
            "tar xzf - -C \"$dir\"\n" ++
            "podman build -f \"$dir/container/Dockerfile\" -t {s} \"$dir\"\n" ++
            "podman image prune -f\n",
        .{ssh.shellQuote(ctx.arena, ctx.settings.image) catch return 1},
    ) catch return 1;

    const out = handSshInput(ctx, script, tarball, 1800) catch |e|
        return ctx.fail("ssh failed: {t}", .{e});
    if (!out.ok()) return ctx.fail("the image did not build (exit {d})", .{out.code});

    ctx.out.print("built {s}\n", .{ctx.settings.image}) catch {};
    return 0;
}

/// Tars capsule's own source for shipping to the VM.
///
/// `COPYFILE_DISABLE=1` is a macOS thing: without it bsdtar adds an `AppleDouble` `._*`
/// member beside every file, which the Linux side then unpacks as litter.
fn packSource(ctx: *Ctx, src: []const u8) ?Io.File {
    const tmp = ctx.environ.get("TMPDIR") orelse "/tmp";
    const path = std.fmt.allocPrint(ctx.arena, "{s}/capsule-src.tgz", .{
        std.mem.trimEnd(u8, tmp, "/"),
    }) catch return null;

    var environ = ctx.environ.clone(ctx.arena) catch return null;
    environ.put("COPYFILE_DISABLE", "1") catch return null;

    const out = exec.run(ctx.arena, ctx.io, &.{
        "tar",  "czf",       path,
        "-C",   src,         "--exclude",
        ".git", "--exclude", ".direnv",
        "bin",  "container", "share",
    }, .{ .environ = &environ }) catch |e| {
        _ = ctx.fail("could not pack the source: {t}", .{e});
        return null;
    };
    if (!out.ok()) {
        _ = ctx.fail("could not pack the source: {s}", .{out.trimmedErr()});
        return null;
    }

    return Io.Dir.cwd().openFile(ctx.io, path, .{}) catch {
        _ = ctx.fail("could not read the packed source", .{});
        return null;
    };
}

/// Removes the shared nix volume if it is there. Returns a non-null exit code only when
/// the removal failed in a way the caller should stop on.
fn dropNixVolume(ctx: *Ctx) ?u8 {
    const remote = "if podman volume exists capsule-nix; then podman volume rm capsule-nix; fi";
    const out = ssh.run(ctx.arena, ctx.io, ctx.sshConfig(), remote, 60) catch |e| {
        return ctx.fail("ssh failed: {t}", .{e});
    };
    if (!out.ok()) return ctx.fail("could not drop the nix volume: {s}", .{out.trimmedErr()});
    return null;
}

/// `vm gc` — prune containers and images, collect nix garbage, then report disk.
fn vmGc(ctx: *Ctx) u8 {
    const cfg = ctx.sshConfig();
    ssh.ensureMaster(ctx.arena, ctx.io, cfg);

    const prune = handSshStream(ctx, "podman container prune -f && podman image prune -f") catch |e|
        return ctx.fail("ssh failed: {t}", .{e});
    if (prune != 0) return ctx.fail("podman prune failed", .{});

    // `check` has already refused an image or container home carrying shell
    // metacharacters, but they are quoted anyway: the validation is a policy and the
    // quoting is the mechanism, and the mechanism should not depend on the policy.
    const collect = std.fmt.allocPrint(
        ctx.arena,
        "podman run --rm -v capsule-nix:/nix -v ~/.capsule/cache:{s}/.cache " ++
            "--security-opt label=disable {s} -c 'nix-collect-garbage'",
        .{
            ssh.shellQuote(ctx.arena, ctx.settings.container_home) catch return 1,
            ssh.shellQuote(ctx.arena, ctx.settings.image) catch return 1,
        },
    ) catch return 1;
    _ = handSshStream(ctx, collect) catch |e|
        return ctx.fail("ssh failed: {t}", .{e});

    const df = ssh.run(ctx.arena, ctx.io, cfg, "df -h /", 30) catch |e|
        return ctx.fail("ssh failed: {t}", .{e});
    ctx.out.writeAll(df.stdout) catch {};
    return 0;
}

/// Whether `path` is there, whatever the reason it might not be.
fn exists(ctx: *Ctx, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(ctx.io, path, .{}) catch return false;
    return true;
}

/// Writes a file only if it is not already there, so re-running `env init` in a project
/// that has half of this cannot clobber the half it has. Reports what it created.
fn createIfAbsent(ctx: *Ctx, path: []const u8, contents: []const u8) bool {
    if (exists(ctx, path)) return true;

    var file = Io.Dir.cwd().createFile(ctx.io, path, .{}) catch {
        _ = ctx.fail("could not create {s}", .{path});
        return false;
    };
    defer file.close(ctx.io);

    var buf: [4096]u8 = undefined;
    var w = file.writer(ctx.io, &buf);
    w.interface.writeAll(contents) catch {
        _ = ctx.fail("could not write {s}", .{path});
        return false;
    };
    w.interface.flush() catch {
        _ = ctx.fail("could not write {s}", .{path});
        return false;
    };

    ctx.out.print("created {s}\n", .{path}) catch {};
    return true;
}

/// `direnv allow`, best-effort — the same treatment `direnv reload` gets, and for the same
/// reason: the scaffolding is already on disk, so refusing to finish over a missing direnv
/// would leave the user with a project and an error rather than a project and a next step.
fn direnvAllow(ctx: *Ctx) void {
    const code = handStream(ctx, &.{ "direnv", "allow" }) catch {
        ctx.err.writeAll("capsule: direnv is not installed — run 'direnv allow' once it is\n") catch {};
        return;
    };
    if (code != 0) {
        ctx.err.writeAll("capsule: 'direnv allow' did not succeed — run it yourself\n") catch {};
    }
}

/// Adds `.direnv/` to `.gitignore`, creating the file when there is none.
///
/// The match is on `.direnv` anywhere in the file, as bash's `grep -q '\.direnv'` was:
/// a project that already ignores it under any spelling should not gain a second entry.
fn ignoreDirenv(ctx: *Ctx) bool {
    const entry = ".direnv/\n";
    if (!exists(ctx, ".gitignore")) return createIfAbsent(ctx, ".gitignore", entry);

    const current = Io.Dir.cwd().readFileAlloc(ctx.io, ".gitignore", ctx.arena, .limited(1 << 20)) catch {
        _ = ctx.fail("could not read .gitignore", .{});
        return false;
    };
    if (std.mem.indexOf(u8, current, ".direnv") != null) return true;

    var file = Io.Dir.cwd().openFile(ctx.io, ".gitignore", .{ .mode = .write_only }) catch {
        _ = ctx.fail("could not write .gitignore", .{});
        return false;
    };
    defer file.close(ctx.io);

    var buf: [256]u8 = undefined;
    var w = file.writer(ctx.io, &buf);
    w.seekTo(current.len) catch {
        _ = ctx.fail("could not append to .gitignore", .{});
        return false;
    };
    const prefix: []const u8 = if (std.mem.endsWith(u8, current, "\n")) "" else "\n";
    w.interface.print("{s}{s}", .{ prefix, entry }) catch {
        _ = ctx.fail("could not append to .gitignore", .{});
        return false;
    };
    w.interface.flush() catch {
        _ = ctx.fail("could not append to .gitignore", .{});
        return false;
    };

    ctx.out.writeAll("added .direnv/ to .gitignore\n") catch {};
    return true;
}

fn envInit(ctx: *Ctx) u8 {
    if (exists(ctx, "flake.nix")) {
        return ctx.fail("flake.nix already exists — refusing to overwrite it", .{});
    }
    if (ctx.args.len > 2) return ctx.fail("usage: capsule env init [lang] [name]", .{});

    const lang: ?*const template.Lang = if (ctx.args.len > 0) template.find(ctx.args[0]) orelse {
        return ctx.fail("unknown language: {s} — available: {s}", .{
            ctx.args[0],
            template.names(ctx.arena) catch "none",
        });
    } else null;

    const name = if (ctx.args.len > 1) ctx.args[1] else blk: {
        const here = git.realpath(ctx.arena, ctx.io, ".") catch
            return ctx.fail("cannot resolve the working directory", .{});
        break :blk std.fs.path.basename(here);
    };
    if (!template.validName(name)) {
        return ctx.fail(
            "'{s}' cannot name a project — pass one: capsule env init [lang] <name>",
            .{name},
        );
    }

    // Packages go in before the file is written, so there is no moment where flake.nix
    // exists without them; bash wrote it and then rewrote it through a temp file.
    var contents = template.renderFlake(ctx.arena, name) catch return 1;
    if (lang) |l| contents = flake.inject(ctx.arena, contents, l.packages) catch return 1;
    if (!writeFlake(ctx, contents)) return 1;
    ctx.out.writeAll("created flake.nix\n") catch {};

    if (lang) |l| {
        if (!createIfAbsent(ctx, "justfile", l.justfile)) return 1;
    }
    if (!createIfAbsent(ctx, ".envrc", "use flake\n")) return 1;
    if (!ignoreDirenv(ctx)) return 1;

    if (!exists(ctx, ".git")) {
        const out = exec.run(ctx.arena, ctx.io, &.{ "git", "init", "-q" }, .{}) catch
            return ctx.fail("git is not installed", .{});
        if (!out.ok()) return ctx.fail("git init failed: {s}", .{out.trimmedErr()});
        ctx.out.writeAll("initialised a git repository\n") catch {};
    }

    direnvAllow(ctx);
    return 0;
}

fn envAdd(ctx: *Ctx) u8 {
    if (ctx.args.len == 0) return ctx.fail("which package?", .{});
    const text = readFlake(ctx) orelse return 1;
    if (!flake.hasMarker(text)) {
        return ctx.fail("flake.nix has no '{s}' marker to add to", .{flake.marker});
    }

    const fresh = flake.newPackages(ctx.arena, text, ctx.args) catch return 1;
    if (fresh.len == 0) {
        ctx.out.writeAll("already present — nothing added\n") catch {};
        return 0;
    }

    const updated = flake.inject(ctx.arena, text, fresh) catch return 1;
    if (!writeFlake(ctx, updated)) return 1;

    for (fresh) |pkg| ctx.out.print("added {s}\n", .{pkg}) catch {};
    direnvReload(ctx);
    return 0;
}

fn envRm(ctx: *Ctx) u8 {
    if (ctx.args.len == 0) return ctx.fail("which package?", .{});
    const text = readFlake(ctx) orelse return 1;

    var removed: std.ArrayList([]const u8) = .empty;
    for (ctx.args) |pkg| {
        if (flake.present(text, pkg)) removed.append(ctx.arena, pkg) catch return 1;
    }
    if (removed.items.len == 0) {
        ctx.out.writeAll("not present — nothing removed\n") catch {};
        return 0;
    }

    const updated = flake.strip(ctx.arena, text, removed.items) catch return 1;
    if (!writeFlake(ctx, updated)) return 1;

    for (removed.items) |pkg| ctx.out.print("removed {s}\n", .{pkg}) catch {};
    direnvReload(ctx);
    return 0;
}

fn envUpdate(ctx: *Ctx) u8 {
    const code = handStream(ctx, &.{ "nix", "flake", "update" }) catch |e|
        return ctx.fail("{t}", .{e});
    if (code != 0) return ctx.fail("nix flake update failed", .{});
    direnvReload(ctx);
    return 0;
}

fn envReload(ctx: *Ctx) u8 {
    direnvReload(ctx);
    return 0;
}

/// Renders one project after a verb changed it.
fn showProject(ctx: *Ctx, p: api.Project) u8 {
    if (ctx.json) return emitJson(ctx, p);
    ctx.out.print("{s}  {s}\n  path     {s}\n  profile  {s}\n  replica  {s}\n", .{
        p.short, p.name, p.path, p.profile, p.replica,
    }) catch {};
    return 0;
}

/// Registration is the explicit barrier: capsule never adopts a directory just because it
/// is a git repository, so this is the only place a project comes into existence.
fn projectAdd(ctx: *Ctx) u8 {
    var profile: []const u8 = "default";
    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        if (std.mem.eql(u8, ctx.args[i], "--profile")) {
            i += 1;
            if (i >= ctx.args.len) return ctx.fail("--profile needs a name", .{});
            profile = ctx.args[i];
        }
    }

    const p = ctx.repoParams();
    const response = api.call(ctx.arena, ctx.io, ctx.socket, api.project_add, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .profile = profile,
    }) catch |e| return ctx.fail("{t}", .{e});

    return switch (response) {
        .ok => |v| showProject(ctx, v),
        .err => |f| failure(ctx, f),
    };
}

fn projectProfile(ctx: *Ctx) u8 {
    if (ctx.args.len == 0) return ctx.fail("which profile?", .{});

    const p = ctx.repoParams();
    const response = api.call(ctx.arena, ctx.io, ctx.socket, api.project_profile, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .profile = ctx.args[0],
    }) catch |e| return ctx.fail("{t}", .{e});

    return switch (response) {
        .ok => |v| showProject(ctx, v),
        .err => |f| failure(ctx, f),
    };
}

fn projectList(ctx: *Ctx) u8 {
    const response = api.call(ctx.arena, ctx.io, ctx.socket, api.project_list, .{}) catch |e|
        return ctx.fail("{t}", .{e});

    const rows = switch (response) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };
    if (ctx.json) return emitJson(ctx, rows);

    if (rows.len == 0) {
        ctx.out.writeAll("no projects registered — 'capsule project add'\n") catch {};
        return 0;
    }
    for (rows) |row| {
        ctx.out.print("{s}  {s: <20}{s}\n", .{ row.short, row.name, row.path }) catch {};
    }
    return 0;
}

fn daemonStatus(ctx: *Ctx) u8 {
    const response = api.call(ctx.arena, ctx.io, ctx.socket, api.daemon_status, .{}) catch
        return ctx.fail("{s}", .{Refusal.no_daemon.message()});

    const status = switch (response) {
        .ok => |v| v,
        .err => |f| return failure(ctx, f),
    };
    if (ctx.json) return emitJson(ctx, status);

    ctx.out.print("socket    {s}\nprojects  {d}\nendpoint  {s}\n", .{
        status.socket, status.projects, @tagName(status.endpoint),
    }) catch {};
    return 0;
}

const State = model.Issue.State;

/// The states each verb's picker offers. `reopen` sees only archived issues, and `edit`
/// sees everything — narrowing is what makes a picker usable rather than a wall.
const any_state: []const State = &.{};
const archived_only: []const State = &.{.archived};
const ready_only: []const State = &.{.ready_for_review};

/// Fetches the project's issues, optionally narrowed to a set of states.
///
/// The narrowing happens here rather than in the daemon because `issue.list` filters on
/// one state only — the same reason the bash picker re-filtered with `jq`. Widening the
/// method to take a set belongs with the board's data work, not with this port.
fn listIssues(ctx: *Ctx, states: []const State) ![]const api.Issue {
    const p = ctx.repoParams();
    const response = try api.call(ctx.arena, ctx.io, ctx.socket, api.issue_list, .{
        .git_common_dir = p.git_common_dir,
        .cwd = p.cwd,
        .state = null,
    });
    const all = switch (response) {
        .ok => |v| v,
        .err => return error.CallFailed,
    };
    if (states.len == 0) return all;

    var kept: std.ArrayList(api.Issue) = .empty;
    for (all) |issue| {
        for (states) |want| {
            if (issue.state == want) {
                try kept.append(ctx.arena, issue);
                break;
            }
        }
    }
    return kept.toOwnedSlice(ctx.arena);
}

/// The id an issue verb should act on: the argument when one was given, otherwise the
/// picker. Returns null when the user chose nothing, which is not an error.
fn resolveIssue(ctx: *Ctx, given: ?[]const u8, states: []const State) !?[]const u8 {
    if (given) |id| if (id.len > 0) return id;

    const issues = try listIssues(ctx, states);
    if (issues.len == 0) return null;

    var rows: std.ArrayList(picker.Row) = .empty;
    for (issues) |issue| {
        try rows.append(ctx.arena, .{
            .id = issue.short,
            .tag = @tagName(issue.state),
            .label = issue.title,
        });
    }

    const chosen = picker.choose(ctx.arena, ctx.arena, "issue>", rows.items) catch |e| switch (e) {
        // Without a terminal there is nobody to pick, so say which argument was missing
        // rather than opening something that cannot be answered.
        error.NotATerminal => return error.NeedsIssueId,
        else => return e,
    };
    const index = chosen orelse return null;
    return issues[index].short;
}

/// Opens `$EDITOR` on a seeded buffer. The header is an HTML comment, because the buffer
/// is markdown and a `#` line would end up in the issue body.
fn editText(ctx: *Ctx, seed: []const u8, header: []const u8) !editor.Result {
    const seeded = if (header.len > 0)
        try std.fmt.allocPrint(ctx.arena, "{s}\n{s}", .{ header, seed })
    else
        seed;

    const tmp = ctx.environ.get("TMPDIR") orelse
        ctx.environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
    return editor.editText(ctx.arena, ctx.io, ctx.environ, seeded, tmp);
}

/// One place that renders a daemon refusal, so the remedy the daemon supplies is always
/// printed and never re-spelled by the caller.
///
/// Three codes carry a bare identifier as their message — `no_project` sends the canonical
/// path, `no_issue` and `ambiguous_id` send the prefix — which alone reads as though
/// capsule were announcing a path rather than refusing one. Naming the code turns it back
/// into a sentence.
fn failure(ctx: *Ctx, f: api.Failure) u8 {
    const written = switch (f.code) {
        .no_project => ctx.err.print("capsule: not a registered project: {s}\n", .{f.message}),
        .no_issue => ctx.err.print("capsule: no such issue: {s}\n", .{f.message}),
        .ambiguous_id => ctx.err.print("capsule: that id matches more than one issue: {s}\n", .{f.message}),
        else => ctx.err.print("capsule: {s}\n", .{f.message}),
    };
    written catch {};
    if (f.hint) |h| ctx.err.print("  try: {s}\n", .{h}) catch {};
    return 1;
}

const testing = std.testing;

test "a container refuses the commands that belong on the host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = std.process.Environ.Map.init(a);
    try environ.put("CAPSULE_IN_CAPSULE", "1");

    var discard: std.ArrayList(u8) = .empty;
    var w = Writer.Allocating.fromArrayList(a, &discard);

    var ctx = Ctx{
        .arena = a,
        .io = testing.io,
        .settings = .{},
        .socket = "/nonexistent.sock",
        .environ = &environ,
        .out = &w.writer,
        .err = &w.writer,
        .args = &.{},
    };

    try testing.expectEqual(Refusal.in_container, checkNeeds(&ctx, cli.find("issue", "list").?).?);
    try testing.expectEqual(Refusal.in_container, checkNeeds(&ctx, cli.find("run", "start").?).?);

    // The one group an agent runs against its own checkout is not refused.
    try testing.expectEqual(@as(?Refusal, null), checkNeeds(&ctx, cli.find("env", "add").?));
}

test "outside a container, a missing daemon is the refusal that names the remedy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = std.process.Environ.Map.init(a);
    var discard: std.ArrayList(u8) = .empty;
    var w = Writer.Allocating.fromArrayList(a, &discard);

    var ctx = Ctx{
        .arena = a,
        .io = testing.io,
        .settings = .{},
        .socket = "/nonexistent/capsule.sock",
        .environ = &environ,
        .out = &w.writer,
        .err = &w.writer,
        .args = &.{},
    };

    const refusal = checkNeeds(&ctx, cli.find("issue", "list").?).?;
    try testing.expectEqual(Refusal.no_daemon, refusal);
    try testing.expect(std.mem.indexOf(u8, refusal.message(), "capsule daemon start") != null);
}

test "a remote vm host refuses the qemu-only verbs before anything else is checked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = std.process.Environ.Map.init(a);
    var discard: std.ArrayList(u8) = .empty;
    var w = Writer.Allocating.fromArrayList(a, &discard);

    var ctx = Ctx{
        .arena = a,
        .io = testing.io,
        .settings = .{ .vm_host = "core@build-box.local" },
        .socket = "/nonexistent.sock",
        .environ = &environ,
        .out = &w.writer,
        .err = &w.writer,
        .args = &.{},
    };

    for ([_][]const u8{ "start", "stop", "disk", "destroy" }) |verb| {
        try testing.expectEqual(
            Refusal.not_local_vm,
            checkNeeds(&ctx, cli.find("vm", verb).?).?,
        );
    }
}

test "every spelling of a local vm host is recognised, and nothing else is" {
    try testing.expect(isLocalVm("core@localhost"));
    try testing.expect(isLocalVm("core@127.0.0.1"));
    try testing.expect(isLocalVm("core@::1"));
    try testing.expect(!isLocalVm("core@build-box"));
    try testing.expect(!isLocalVm("core@localhost.evil.com"));
    // A host with no user is not local; `config.check` refuses it long before this.
    try testing.expect(!isLocalVm("localhost"));
}

test "every refusal has a distinct message and names its remedy where there is one" {
    var seen: [6][]const u8 = undefined;
    var n: usize = 0;
    for (std.enums.values(Refusal)) |r| {
        const m = r.message();
        try testing.expect(m.len > 0);
        for (seen[0..n]) |prior| try testing.expect(!std.mem.eql(u8, prior, m));
        seen[n] = m;
        n += 1;
    }
    try testing.expect(std.mem.indexOf(u8, Refusal.no_daemon.message(), "capsule daemon start") != null);
    try testing.expect(std.mem.indexOf(u8, Refusal.no_remote.message(), "capsule run start") != null);
}

/// Every (group, verb) `run` has a branch for. Kept beside the test rather than inside it
/// so adding a handler and forgetting the table is one obvious edit, not a hunt through a
/// boolean expression.
const handled = [_][2][]const u8{
    .{ "run", "list" },      .{ "run", "fetch" },     .{ "run", "push" },        .{ "run", "merge" },
    .{ "env", "init" },      .{ "env", "add" },       .{ "env", "rm" },          .{ "env", "update" },
    .{ "env", "reload" },    .{ "daemon", "status" }, .{ "daemon", "start" },    .{ "daemon", "stop" },
    .{ "project", "list" },  .{ "project", "add" },   .{ "project", "profile" }, .{ "issue", "list" },
    .{ "issue", "new" },     .{ "issue", "comment" }, .{ "issue", "state" },     .{ "issue", "rename" },
    .{ "issue", "archive" }, .{ "issue", "reopen" },  .{ "issue", "edit" },      .{ "issue", "triage" },
    .{ "memory", "list" },   .{ "memory", "review" }, .{ "memory", "new" },      .{ "vm", "status" },
    .{ "vm", "ssh" },        .{ "vm", "gc" },         .{ "image", "pull" },      .{ "run", "start" },
    .{ "run", "attach" },    .{ "vm", "start" },      .{ "vm", "stop" },         .{ "vm", "disk" },
    .{ "vm", "destroy" },    .{ "run", "end" },       .{ "run", "review" },      .{ "run", "reset" },
    .{ "project", "rm" },    .{ "login", "" },        .{ "image", "build" },
};

test "a run directory is recovered from its container name by the prefix, not by bytes" {
    // `std.mem.trimStart` takes a *set* of bytes, so trimming "capsule-" off
    // "capsule-abc123" would also eat the leading 'a' — and every later character that
    // happened to be one of c,a,p,s,u,l,e,-. The result is a real path that is the wrong
    // one, which is the worst kind of wrong.
    const prefix = "capsule-";
    for ([_][2][]const u8{
        .{ "capsule-abc123456789", "abc123456789" },
        .{ "capsule-caps1e2e3e4e", "caps1e2e3e4e" },
        .{ "capsule-elapsed00000", "elapsed00000" },
        .{ "not-ours", "not-ours" },
    }) |case| {
        const got = if (std.mem.startsWith(u8, case[0], prefix)) case[0][prefix.len..] else case[0];
        try testing.expectEqualStrings(case[1], got);
    }
}

test "the short form of an id is its last eight characters" {
    try testing.expectEqualStrings("2a1c9f0e", shortId("018f2a1c9f0e"));
    try testing.expectEqualStrings("abc", shortId("abc"));
    try testing.expectEqualStrings("", shortId(""));
    try testing.expectEqualStrings("12345678", shortId("12345678"));
}

test "vm ssh hands its arguments to the remote shell, as plain ssh does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The escape hatch has to reach the remote shell intact: a tilde, a `$VAR` or a glob
    // typed here is meant to expand *there*. An earlier version quoted each argument,
    // which made `vm ssh 'ls ~/capsule'` one literal word and broke the command's purpose.
    try testing.expectEqualStrings(
        "ls ~/capsule",
        try std.mem.join(a, " ", &.{ "ls", "~/capsule" }),
    );
    try testing.expectEqualStrings(
        "git -C ~/capsule/x log --oneline",
        try std.mem.join(a, " ", &.{ "git", "-C", "~/capsule/x", "log", "--oneline" }),
    );
}

test "a command marked ported has a handler, and one that is not says so" {
    // The dispatcher's fallthrough exists so a table edit that forgets a handler is a
    // clear message rather than a silent success.
    for (&cli.commands) |*c| {
        if (!c.ported) continue;
        var known = false;
        for (handled) |h| {
            if (std.mem.eql(u8, c.group, h[0]) and std.mem.eql(u8, c.verb, h[1])) known = true;
        }
        if (!known) {
            std.debug.print("'{s} {s}' is marked ported but run() has no branch\n", .{ c.group, c.verb });
            return error.PortedWithoutHandler;
        }
    }
}
