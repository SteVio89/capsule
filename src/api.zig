//! The wire protocol as Zig types, declared once and used by both sides.
//!
//! The CLI and the daemon are the same binary, but until now the protocol crossed between
//! them as hand-built strings in both directions: bash concatenated request JSON with
//! `jq`, and the daemon hand-wrote response envelopes at two dozen sites whose brace
//! balance no test checked. Declaring each method's params and result as a struct makes
//! the encoder and the decoder the same declaration, so they cannot disagree.
//!
//! Field order in a `Result` is significant: `std.json.Stringify` emits struct fields in
//! declaration order, and the order here reproduces the bytes the hand-written writers
//! produced. The tests at the bottom assert that byte-for-byte. Field order in a `Params`
//! is not significant — the daemon reads those by key.

const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;

const protocol = @import("protocol.zig");
const model = @import("model.zig");
const client = @import("client.zig");

/// One method: its name on the wire, what it takes, and what it returns. `Result` may be
/// a struct or a slice — a slice becomes a top-level JSON array, which three methods use.
pub fn Method(
    comptime method_name: []const u8,
    comptime P: type,
    comptime R: type,
) type {
    return struct {
        pub const name = method_name;
        pub const Params = P;
        pub const Result = R;
    };
}

/// Which repository the call is about. Every method except the four daemon-level ones
/// takes these two, and the daemon resolves them to a canonical path.
///
/// `cwd` is passed already realpath'd by the caller rather than resolved here, because it
/// is the caller's working directory and the daemon's is irrelevant.
pub const Repo = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
};

// ---------------------------------------------------------------------------
// Result shapes
// ---------------------------------------------------------------------------

pub const Project = struct {
    short: []const u8,
    name: []const u8,
    path: []const u8,
    profile: []const u8,
    replica: []const u8,
};

pub const Issue = struct {
    short: []const u8,
    id: []const u8,
    /// The enum, not a string: `Stringify` writes `@tagName` and the parser accepts it,
    /// which is what removes the third hand-maintained copy of the state vocabulary.
    state: model.Issue.State,
    title: []const u8,
    body: []const u8,
    /// Null on an issue with no events yet. Always present as a key — the CLI uses it as
    /// an optimistic-concurrency token and must be able to tell absent from unset.
    last_event_id: ?[]const u8,
};

pub const Run = struct {
    short: []const u8,
    /// The 8-character short form here, unlike `RunStart.issue`, which is the full id.
    issue: []const u8,
    state: model.Run.State,
    started_at: i64,
    ended_at: ?i64,
    container: []const u8,
    branch: []const u8,
};

/// `run.start`'s result carries the only copy of the token that is ever emitted.
pub const RunStart = struct {
    run: []const u8,
    issue: []const u8,
    token: []const u8,
    container: []const u8,
    profile: []const u8,
    branch: []const u8,
    title: []const u8,
};

/// One count per `model.Issue.State`, in declaration order. A new state adds a field here
/// and the compiler finds every place that must handle it.
pub const IssueCounts = struct {
    proposed: usize = 0,
    open: usize = 0,
    in_progress: usize = 0,
    blocked: usize = 0,
    ready_for_review: usize = 0,
    done: usize = 0,
    archived: usize = 0,
};

pub const MemoryStats = struct {
    active: usize,
    cap: usize,
    proposed: usize,
    tokens: usize,
    over_budget: bool,
};

pub const Summary = struct {
    replica: []const u8,
    issues: IssueCounts,
    memory: MemoryStats,
};

pub const Memory = struct {
    short: []const u8,
    state: model.Memory.State,
    body: []const u8,
    anchors: []const u8,
};

/// `memory.stale` omits `state` and trims `anchors`, where `memory.list` keeps both. The
/// asymmetry is preserved rather than tidied: it is on the wire today and the CLI reads
/// the two shapes differently.
pub const StaleMemory = struct {
    short: []const u8,
    body: []const u8,
    anchors: []const u8,
};

/// `dir` is the FIRST 12 hex characters of the run id, where `Run.short` is the LAST 8.
/// The two are not interchangeable and never have been.
pub const GcRun = struct {
    dir: []const u8,
    container: []const u8,
};

pub const Container = struct {
    name: []const u8,
    image: []const u8,
};

pub const Branch = struct {
    project: []const u8,
    name: []const u8,
    commits: u64,
};

/// Deliberately without `image_digest`: the probe collects it and `writeSnapshot` has
/// never serialised it. Adding it here would change the wire, which belongs in the board
/// work rather than in a protocol port.
pub const World = struct {
    reachable: bool,
    observed_at_ms: i64,
    uptime_s: ?u64,
    disk_used: ?u64,
    disk_total: ?u64,
    containers: []const Container,
    branches: []const Branch,
};

pub const DaemonStatus = struct {
    socket: []const u8,
    projects: u64,
    endpoint: Endpoint,

    pub const Endpoint = enum { up, down };
};

pub const TriageBuffer = struct {
    count: usize,
    buffer: []const u8,
};

pub const TriageApplied = struct {
    accepted: usize,
    rejected: usize,
};

pub const ReviewBuffer = struct {
    proposals: usize,
    active: usize,
    buffer: []const u8,
};

pub const ReviewApplied = struct {
    changed: usize,
};

pub const Pong = struct { pong: bool };
pub const Removed = struct { removed: bool };
pub const Ended = struct { ended: bool };
pub const Added = struct { added: bool };
pub const Stopping = struct { stopping: bool };

// ---------------------------------------------------------------------------
// Param shapes
// ---------------------------------------------------------------------------

pub const NoParams = struct {};

pub const RepoParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
};

pub const ProfileParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    profile: []const u8 = "default",
};

pub const RemoveParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    force: bool = false,
};

pub const NewIssueParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    title: []const u8,
    body: []const u8 = "",
};

pub const ListIssuesParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    /// Null lists every state.
    state: ?model.Issue.State = null,
};

pub const IdParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    id: []const u8,
};

pub const EditIssueParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    id: []const u8,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    /// The issue's `last_event_id` when it was read. A mismatch is a `conflict`.
    last_event_id: ?[]const u8 = null,
};

pub const StateParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    id: []const u8,
    state: model.Issue.State,
};

pub const MergeParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    id: []const u8,
    commit: []const u8 = "",
};

pub const ReasonParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    id: []const u8,
    reason: []const u8 = "",
};

pub const CommentParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    id: []const u8,
    text: []const u8,
};

pub const BufferParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    buffer: []const u8,
};

pub const StartRunParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    issue: []const u8,
};

pub const NewMemoryParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    body: []const u8,
    anchors: []const u8 = "",
};

pub const StaleParams = struct {
    git_common_dir: []const u8,
    cwd: []const u8,
    /// Repo-relative paths that have gone. Empty means nothing can be suspect.
    paths: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// The methods
// ---------------------------------------------------------------------------

pub const ping = Method("ping", NoParams, Pong);
pub const daemon_status = Method("daemon.status", NoParams, DaemonStatus);
pub const daemon_stop = Method("daemon.stop", NoParams, Stopping);
pub const world_get = Method("world.get", NoParams, World);

pub const project_list = Method("project.list", NoParams, []const Project);
pub const project_add = Method("project.add", ProfileParams, Project);
pub const project_get = Method("project.get", RepoParams, Project);
pub const project_profile = Method("project.profile", ProfileParams, Project);
pub const project_rm = Method("project.rm", RemoveParams, Removed);

pub const issue_new = Method("issue.new", NewIssueParams, Issue);
pub const issue_list = Method("issue.list", ListIssuesParams, []const Issue);
pub const issue_summary = Method("issue.summary", RepoParams, Summary);
pub const issue_get = Method("issue.get", IdParams, Issue);
pub const issue_edit = Method("issue.edit", EditIssueParams, Issue);
pub const issue_rename = Method("issue.rename", EditIssueParams, Issue);
pub const issue_state = Method("issue.state", StateParams, Issue);
pub const issue_merge = Method("issue.merge", MergeParams, Issue);
pub const issue_archive = Method("issue.archive", ReasonParams, Issue);
pub const issue_reopen = Method("issue.reopen", ReasonParams, Issue);
pub const issue_comment = Method("issue.comment", CommentParams, Issue);
pub const issue_triage_load = Method("issue.triage.load", RepoParams, TriageBuffer);
pub const issue_triage_apply = Method("issue.triage.apply", BufferParams, TriageApplied);

pub const run_list = Method("run.list", RepoParams, []const Run);
pub const run_start = Method("run.start", StartRunParams, RunStart);
pub const run_end = Method("run.end", RepoParams, Ended);

pub const memory_stale = Method("memory.stale", StaleParams, []const StaleMemory);
pub const memory_list = Method("memory.list", RepoParams, []const Memory);
pub const memory_new = Method("memory.new", NewMemoryParams, Added);
pub const memory_review_load = Method("memory.review.load", RepoParams, ReviewBuffer);
pub const memory_review_apply = Method("memory.review.apply", BufferParams, ReviewApplied);

pub const gc_branches = Method("gc.branches", RepoParams, []const []const u8);
pub const gc_runs = Method("gc.runs", RepoParams, []const GcRun);

/// Every method, so a test can assert the set is complete and the router can be built
/// from data rather than from a chain of `std.mem.startsWith`.
pub const all = .{
    ping,               daemon_status,       daemon_stop,  world_get,
    project_list,       project_add,         project_get,  project_profile,
    project_rm,         issue_new,           issue_list,   issue_summary,
    issue_get,          issue_edit,          issue_rename, issue_state,
    issue_merge,        issue_archive,       issue_reopen, issue_comment,
    issue_triage_load,  issue_triage_apply,  run_list,     run_start,
    run_end,            memory_stale,        memory_list,  memory_new,
    memory_review_load, memory_review_apply, gc_branches,  gc_runs,
};

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// The options every capsule payload is written with. Null optionals are emitted as
/// `null` rather than omitted, because the two fields that are optional on the wire
/// (`last_event_id`, `ended_at`) have always been present-and-null.
pub const stringify_options: std.json.Stringify.Options = .{
    .whitespace = .minified,
    .emit_null_optional_fields = true,
};

/// `{"id":N,"ok":true,"result":<result>}` plus a newline — the framing the socket uses.
pub fn writeOk(w: *Writer, id: u64, result: anytype) !void {
    try w.print("{{\"id\":{d},\"ok\":true,\"result\":", .{id});
    try std.json.Stringify.value(result, stringify_options, w);
    try w.writeAll("}\n");
}

/// `hint` overrides the one the code carries. `run.start` is the reason this is a
/// parameter: it refuses with `refused`, which has no hint of its own, but wants to name
/// `capsule run attach`. Pass null to use the code's own hint.
pub fn writeErr(
    w: *Writer,
    id: u64,
    code: protocol.Code,
    message: []const u8,
    hint: ?[]const u8,
) !void {
    try w.print("{{\"id\":{d},\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":", .{
        id, @tagName(code),
    });
    try std.json.Stringify.encodeJsonString(message, stringify_options, w);
    if (hint orelse code.hint()) |h| {
        try w.writeAll(",\"hint\":");
        try std.json.Stringify.encodeJsonString(h, stringify_options, w);
    }
    try w.writeAll("}}\n");
}

/// Encodes a request line, newline included.
pub fn writeRequest(w: *Writer, id: u64, comptime M: type, params: M.Params) !void {
    try w.print("{{\"id\":{d},\"method\":\"{s}\",\"params\":", .{ id, M.name });
    try std.json.Stringify.value(params, stringify_options, w);
    try w.writeAll("}\n");
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Parses a request's `params` into the method's typed shape.
///
/// Unknown fields are ignored so a newer CLI talking to an older daemon loses a field
/// rather than the whole call. A missing field with a default takes the default; a
/// missing field without one is `error.MissingField`, which the caller reports as
/// `bad_params`.
pub fn parseParams(
    comptime M: type,
    arena: std.mem.Allocator,
    value: std.json.Value,
) !M.Params {
    if (@typeInfo(M.Params).@"struct".fields.len == 0) return M.Params{};
    return std.json.parseFromValueLeaky(M.Params, arena, value, .{
        .ignore_unknown_fields = true,
    });
}

/// Parses a result body — the raw JSON of the `result` member — into the method's shape.
pub fn parseResult(
    comptime M: type,
    arena: std.mem.Allocator,
    body: []const u8,
) !M.Result {
    return std.json.parseFromSliceLeaky(M.Result, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// What a call came back with. The error case keeps `message` free-form because the
/// daemon puts a canonical path, a prose refusal, or a buffer parser's complaint there.
pub fn Response(comptime R: type) type {
    return union(enum) {
        ok: R,
        err: Failure,

        pub fn unwrap(self: @This()) !R {
            return switch (self) {
                .ok => |v| v,
                .err => error.CallFailed,
            };
        }
    };
}

pub const Failure = struct {
    code: protocol.Code,
    message: []const u8,
    hint: ?[]const u8,
};

/// One typed round trip over the socket. Replaces the `capsuled <method> '<json>'`
/// subprocess the CLI used to spawn for every call, along with the `jq` that built the
/// request and the `jq` that took the response apart.
pub fn call(
    arena: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    comptime M: type,
    params: M.Params,
) !Response(M.Result) {
    const params_json = try std.json.Stringify.valueAlloc(arena, params, stringify_options);
    const response = try client.call(arena, io, socket_path, M.name, params_json);

    if (!response.ok) {
        return .{ .err = .{
            .code = if (response.code) |c|
                std.meta.stringToEnum(protocol.Code, c) orelse .internal
            else
                .internal,
            .message = response.message orelse response.body,
            .hint = response.hint,
        } };
    }
    return .{ .ok = try parseResult(M, arena, response.body) };
}

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

/// Renders through the real envelope writer so the assertions below are on the exact
/// bytes a client would read off the socket.
fn encoded(arena: std.mem.Allocator, result: anytype) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var w = Writer.Allocating.fromArrayList(arena, &out);
    try writeOk(&w.writer, 1, result);
    return w.written();
}

test "an issue serialises to exactly the bytes the hand-written writer produced" {
    var a = testArena();
    defer a.deinit();

    const got = try encoded(a.allocator(), Issue{
        .short = "3f2a1b9c",
        .id = "0192f2a13f2a1b9c0192f2a13f2a1b9c",
        .state = .in_progress,
        .title = "make the board useful",
        .body = "the body",
        .last_event_id = "0192f2a13f2a1b9c0192f2a13f2a1b9d",
    });
    try testing.expectEqualStrings(
        "{\"id\":1,\"ok\":true,\"result\":{\"short\":\"3f2a1b9c\"," ++
            "\"id\":\"0192f2a13f2a1b9c0192f2a13f2a1b9c\",\"state\":\"in_progress\"," ++
            "\"title\":\"make the board useful\",\"body\":\"the body\"," ++
            "\"last_event_id\":\"0192f2a13f2a1b9c0192f2a13f2a1b9d\"}}\n",
        got,
    );
}

test "a null last_event_id is present as null, never omitted" {
    var a = testArena();
    defer a.deinit();
    const got = try encoded(a.allocator(), Issue{
        .short = "3f2a1b9c",
        .id = "0192f2a13f2a1b9c0192f2a13f2a1b9c",
        .state = .open,
        .title = "t",
        .body = "",
        .last_event_id = null,
    });
    try testing.expect(std.mem.indexOf(u8, got, "\"last_event_id\":null}") != null);
}

test "a branch name's slash is not escaped" {
    var a = testArena();
    defer a.deinit();
    const got = try encoded(a.allocator(), Run{
        .short = "019fb1ce",
        .issue = "3f2a1b9c",
        .state = .active,
        .started_at = 1234,
        .ended_at = null,
        .container = "capsule-019fb1ce23cd",
        .branch = "capsule/0192f2a13f2a1b9c0192f2a13f2a1b9c",
    });
    try testing.expect(std.mem.indexOf(u8, got, "capsule/0192f2a1") != null);
    try testing.expect(std.mem.indexOf(u8, got, "capsule\\/") == null);
    try testing.expect(std.mem.indexOf(u8, got, "\"ended_at\":null") != null);
}

test "a title carrying quotes, tabs and backslashes round-trips" {
    var a = testArena();
    defer a.deinit();

    const nasty = "a \"quoted\" \\ back \t tab \n newline";
    const wire = try encoded(a.allocator(), Issue{
        .short = "3f2a1b9c",
        .id = "x",
        .state = .open,
        .title = nasty,
        .body = nasty,
        .last_event_id = null,
    });

    // Strip the envelope and parse the result back through the typed decoder.
    const start = std.mem.indexOf(u8, wire, "\"result\":").? + "\"result\":".len;
    const body = wire[start .. wire.len - 2];
    const back = try parseResult(issue_get, a.allocator(), body);
    try testing.expectEqualStrings(nasty, back.title);
    try testing.expectEqualStrings(nasty, back.body);
}

test "a top-level array result stays an array, and empty stays []" {
    var a = testArena();
    defer a.deinit();

    const rows = [_]Project{.{
        .short = "abc12345",
        .name = "capsule",
        .path = "/home/me/code/capsule/.git",
        .profile = "default",
        .replica = "capsule-abc12345",
    }};
    const got = try encoded(a.allocator(), @as([]const Project, &rows));
    try testing.expectEqualStrings(
        "{\"id\":1,\"ok\":true,\"result\":[{\"short\":\"abc12345\",\"name\":\"capsule\"," ++
            "\"path\":\"/home/me/code/capsule/.git\",\"profile\":\"default\"," ++
            "\"replica\":\"capsule-abc12345\"}]}\n",
        got,
    );

    const none = try encoded(a.allocator(), @as([]const Project, &.{}));
    try testing.expectEqualStrings("{\"id\":1,\"ok\":true,\"result\":[]}\n", none);
}

test "the world model keeps its nulls and omits image_digest" {
    var a = testArena();
    defer a.deinit();
    const got = try encoded(a.allocator(), World{
        .reachable = false,
        .observed_at_ms = 0,
        .uptime_s = null,
        .disk_used = null,
        .disk_total = null,
        .containers = &.{},
        .branches = &.{},
    });
    try testing.expectEqualStrings(
        "{\"id\":1,\"ok\":true,\"result\":{\"reachable\":false,\"observed_at_ms\":0," ++
            "\"uptime_s\":null,\"disk_used\":null,\"disk_total\":null," ++
            "\"containers\":[],\"branches\":[]}}\n",
        got,
    );
    try testing.expect(std.mem.indexOf(u8, got, "image_digest") == null);
}

test "the summary's issue counts carry one key per state, in enum order" {
    var a = testArena();
    defer a.deinit();
    const got = try encoded(a.allocator(), Summary{
        .replica = "capsule-abc12345",
        .issues = .{ .proposed = 2, .open = 3, .in_progress = 1, .ready_for_review = 4, .done = 7 },
        .memory = .{ .active = 12, .cap = 40, .proposed = 2, .tokens = 2100, .over_budget = false },
    });
    try testing.expectEqualStrings(
        "{\"id\":1,\"ok\":true,\"result\":{\"replica\":\"capsule-abc12345\"," ++
            "\"issues\":{\"proposed\":2,\"open\":3,\"in_progress\":1,\"blocked\":0," ++
            "\"ready_for_review\":4,\"done\":7,\"archived\":0}," ++
            "\"memory\":{\"active\":12,\"cap\":40,\"proposed\":2,\"tokens\":2100," ++
            "\"over_budget\":false}}}\n",
        got,
    );
}

test "the issue-count field set matches the state enum exactly" {
    // If a state is added and IssueCounts is not updated, the summary would silently stop
    // reporting it. This is the assertion that turns that into a build failure.
    const states = @typeInfo(model.Issue.State).@"enum".fields;
    const counts = @typeInfo(IssueCounts).@"struct".fields;
    try testing.expectEqual(states.len, counts.len);
    inline for (states, counts) |state, count| {
        try testing.expectEqualStrings(state.name, count.name);
    }
}

test "an error carries the code's own hint" {
    var a = testArena();
    defer a.deinit();
    var out: std.ArrayList(u8) = .empty;
    var w = Writer.Allocating.fromArrayList(a.allocator(), &out);
    try writeErr(&w.writer, 1, .no_project, "not a registered project", null);
    try testing.expectEqualStrings(
        "{\"id\":1,\"ok\":false,\"error\":{\"code\":\"no_project\"," ++
            "\"message\":\"not a registered project\",\"hint\":\"capsule project add\"}}\n",
        w.written(),
    );
}

test "an overridden hint reaches a code that has none of its own" {
    var a = testArena();
    defer a.deinit();
    var out: std.ArrayList(u8) = .empty;
    var w = Writer.Allocating.fromArrayList(a.allocator(), &out);
    try writeErr(&w.writer, 1, .refused, "a run is already live", "capsule run attach");
    try testing.expectEqualStrings(
        "{\"id\":1,\"ok\":false,\"error\":{\"code\":\"refused\"," ++
            "\"message\":\"a run is already live\",\"hint\":\"capsule run attach\"}}\n",
        w.written(),
    );

    // Without the override the same code emits no hint at all.
    var bare: std.ArrayList(u8) = .empty;
    var bw = Writer.Allocating.fromArrayList(a.allocator(), &bare);
    try writeErr(&bw.writer, 1, .refused, "nope", null);
    try testing.expect(std.mem.indexOf(u8, bw.written(), "hint") == null);
}

test "a request line encodes the method and its params" {
    var a = testArena();
    defer a.deinit();
    var out: std.ArrayList(u8) = .empty;
    var w = Writer.Allocating.fromArrayList(a.allocator(), &out);
    try writeRequest(&w.writer, 7, issue_get, .{
        .git_common_dir = "/repo/.git",
        .cwd = "/repo",
        .id = "3f2a1b9c",
    });
    try testing.expectEqualStrings(
        "{\"id\":7,\"method\":\"issue.get\",\"params\":{\"git_common_dir\":\"/repo/.git\"," ++
            "\"cwd\":\"/repo\",\"id\":\"3f2a1b9c\"}}\n",
        w.written(),
    );
}

test "params take their defaults when the key is absent" {
    var a = testArena();
    defer a.deinit();

    const value = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(),
        \\{"git_common_dir":"/repo/.git","cwd":"/repo"}
    , .{});

    const profile = try parseParams(project_add, a.allocator(), value);
    try testing.expectEqualStrings("default", profile.profile);

    const rm = try parseParams(project_rm, a.allocator(), value);
    try testing.expect(!rm.force);

    const list = try parseParams(issue_list, a.allocator(), value);
    try testing.expectEqual(@as(?model.Issue.State, null), list.state);

    const stale = try parseParams(memory_stale, a.allocator(), value);
    try testing.expectEqual(@as(usize, 0), stale.paths.len);
}

test "a required param that is missing is an error, not a silent empty string" {
    var a = testArena();
    defer a.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(),
        \\{"git_common_dir":"/repo/.git","cwd":"/repo"}
    , .{});
    try testing.expectError(error.MissingField, parseParams(issue_get, a.allocator(), value));
    try testing.expectError(error.MissingField, parseParams(issue_new, a.allocator(), value));
}

test "an unknown param is ignored rather than failing the call" {
    var a = testArena();
    defer a.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(),
        \\{"git_common_dir":"/repo/.git","cwd":"/repo","from_the_future":true}
    , .{});
    const got = try parseParams(project_get, a.allocator(), value);
    try testing.expectEqualStrings("/repo", got.cwd);
}

test "a state param parses from its tag name and rejects anything else" {
    var a = testArena();
    defer a.deinit();

    const good = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(),
        \\{"git_common_dir":"/g","cwd":"/c","id":"abc","state":"ready_for_review"}
    , .{});
    const parsed = try parseParams(issue_state, a.allocator(), good);
    try testing.expectEqual(model.Issue.State.ready_for_review, parsed.state);

    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(),
        \\{"git_common_dir":"/g","cwd":"/c","id":"abc","state":"nonsense"}
    , .{});
    try testing.expectError(error.InvalidEnumTag, parseParams(issue_state, a.allocator(), bad));
}

test "every method name is unique and non-empty" {
    @setEvalBranchQuota(10_000);
    comptime var seen: []const []const u8 = &.{};
    inline for (all) |M| {
        comptime {
            if (M.name.len == 0) @compileError("a method has an empty name");
            for (seen) |prior| {
                if (std.mem.eql(u8, prior, M.name)) @compileError("duplicate method: " ++ M.name);
            }
            seen = seen ++ [_][]const u8{M.name};
        }
    }
    try testing.expectEqual(@as(usize, 32), all.len);
}

test "no params struct is ever missing the repo fields it needs" {
    // Everything but the four daemon-level methods addresses a project, and the daemon
    // resolves that from these two fields. A params struct that forgot them would fail at
    // runtime with a confusing "not a git repository".
    inline for (all) |M| {
        if (M.Params == NoParams) continue;
        const fields = @typeInfo(M.Params).@"struct".fields;
        comptime var has_git = false;
        comptime var has_cwd = false;
        inline for (fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "git_common_dir")) has_git = true;
            if (comptime std.mem.eql(u8, f.name, "cwd")) has_cwd = true;
        }
        try testing.expect(has_git);
        try testing.expect(has_cwd);
    }
}
