//! The only file that knows SQL.

const std = @import("std");
const sqlite = @import("sqlite");
const model = @import("model.zig");
const replay = @import("replay.zig");
const ids = @import("id.zig");

const Id = ids.Id;

pub const schema = @embedFile("schema.sql");

/// The store's own failures. sqlite's errors and the allocator's come through the
/// inferred error set of each function.
pub const Error = error{ IllegalTransition, NoSuchIssue, HasIssues, Conflict };

/// Ids are BLOBs in every table, so they bind as blobs — a bare `[16]u8` would bind as
/// TEXT.
fn blob(id: *const Id) sqlite.Blob {
    return .{ .data = id };
}

pub const Store = struct {
    db: sqlite.Db,

    /// Opens (creating if needed) the database at `path` and applies the schema, which
    /// is written to be idempotent. `:memory:` works and is what the tests use.
    pub fn open(path: [:0]const u8) !Store {
        var db = try sqlite.Db.init(.{
            .mode = if (std.mem.eql(u8, path, ":memory:")) .Memory else .{ .File = path },
            .open_flags = .{ .write = true, .create = true },
            .threading_mode = .Serialized,
        });
        errdefer db.deinit();

        _ = db.pragma(void, .{}, "journal_mode", "WAL") catch {};
        _ = try db.pragma(void, .{}, "foreign_keys", "1");

        var s = Store{ .db = db };
        try s.execScript(schema);
        return s;
    }

    /// Closes the underlying connection. The store is unusable afterwards.
    pub fn close(s: *Store) void {
        s.db.deinit();
    }

    /// Several statements in one string, which `exec` cannot do — it compiles the first
    /// and silently drops the rest.
    fn execScript(s: *Store, sql: [:0]const u8) !void {
        const rc = sqlite.c.sqlite3_exec(s.db.db, sql.ptr, null, null, null);
        if (rc != sqlite.c.SQLITE_OK) return sqlite.errorFromResultCode(rc);
    }

    /// Registers a project. `canonical_path` is unique — registering the same path twice
    /// is `error.SQLiteConstraint`, not an upsert.
    pub fn addProject(s: *Store, id: Id, canonical_path: []const u8, profile: []const u8, now_ms: i64) !void {
        var stmt = try s.db.prepare(
            "INSERT INTO projects(id, canonical_path, profile, created_at) VALUES(?,?,?,?);",
        );
        defer stmt.deinit();
        // Resetting consumes the violation, which is an expected answer here: sqlite
        // reports it again from finalize, and zig-sqlite logs that at error level.
        errdefer _ = sqlite.c.sqlite3_reset(stmt.dynamic().stmt);
        try stmt.exec(.{}, .{ blob(&id), canonical_path, profile, now_ms });
    }

    /// The project id registered under exactly this canonical path, or null. No path
    /// normalisation happens here — the caller canonicalises before asking.
    pub fn findProject(s: *Store, canonical_path: []const u8) !?Id {
        return s.db.one(Id, "SELECT id FROM projects WHERE canonical_path = ?;", .{}, .{canonical_path});
    }

    pub const ProjectRow = struct {
        id: Id,
        canonical_path: []const u8,
        profile: []const u8,
    };

    /// Rows are copied into `arena` rather than handed out as sqlite's own buffers, which
    /// the next step would invalidate underneath the caller.
    pub fn listProjects(s: *Store, arena: std.mem.Allocator) ![]ProjectRow {
        var stmt = try s.db.prepare("SELECT id, canonical_path, profile FROM projects ORDER BY id;");
        defer stmt.deinit();
        return stmt.all(ProjectRow, arena, .{}, .{});
    }

    /// The project's profile name, copied into `arena` (the caller's arena owns it), or
    /// null when no such project exists.
    pub fn projectProfile(s: *Store, arena: std.mem.Allocator, id: Id) !?[]const u8 {
        return s.db.oneAlloc(
            []const u8,
            arena,
            "SELECT profile FROM projects WHERE id = ?;",
            .{},
            .{blob(&id)},
        );
    }

    /// Points the project at a different profile. Writing to a nonexistent project is
    /// not an error — zero rows simply match.
    pub fn setProjectProfile(s: *Store, id: Id, profile: []const u8) !void {
        try s.db.exec("UPDATE projects SET profile = ? WHERE id = ?;", .{}, .{ profile, blob(&id) });
    }

    /// How many issues the project has, in any state.
    pub fn countIssues(s: *Store, project_id: Id) !i64 {
        return (try s.db.one(
            i64,
            "SELECT count(*) FROM issues WHERE project_id = ?;",
            .{},
            .{blob(&project_id)},
        )) orelse 0;
    }

    /// Refuses while issues exist unless forced. A typo'd `rm` is the one failure here
    /// with no undo, and the events are append-only precisely so they are not disposable.
    pub fn removeProject(s: *Store, id: Id, force: bool) !void {
        if (!force and try s.countIssues(id) > 0) return error.HasIssues;

        try s.db.exec("SAVEPOINT rm_project;", .{}, .{});
        errdefer s.execScript("ROLLBACK TO rm_project; RELEASE rm_project;") catch {};

        inline for (.{
            "DELETE FROM events WHERE issue_id IN (SELECT id FROM issues WHERE project_id = ?);",
            "DELETE FROM runs WHERE project_id = ?;",
            "DELETE FROM memories WHERE project_id = ?;",
            "DELETE FROM issues WHERE project_id = ?;",
            "DELETE FROM projects WHERE id = ?;",
        }) |sql| {
            try s.db.exec(sql, .{}, .{blob(&id)});
        }

        try s.db.exec("RELEASE rm_project;", .{}, .{});
    }

    /// How many projects are registered.
    pub fn countProjects(s: *Store) !i64 {
        return (try s.db.one(i64, "SELECT count(*) FROM projects;", .{}, .{})) orelse 0;
    }

    /// Creates an issue and its opening event together. The state is not passed in — it
    /// comes from replaying the event, like every other transition.
    pub fn createIssue(
        s: *Store,
        issue_id: Id,
        project_id: Id,
        title: []const u8,
        body: []const u8,
        actor: model.Event.Actor,
        event_id: Id,
        now_ms: i64,
    ) !model.Issue.State {
        const kind: model.Event.Kind = if (actor == .agent) .filed_by_agent else .created;
        const outcome = replay.apply(null, .{ .kind = kind, .actor = actor });
        const state = switch (outcome) {
            .moved => |next| next,
            else => return error.IllegalTransition,
        };

        try s.db.exec("SAVEPOINT create_issue;", .{}, .{});
        errdefer s.execScript("ROLLBACK TO create_issue; RELEASE create_issue;") catch {};

        try s.db.exec(
            "INSERT INTO issues(id, project_id, title, body, state, created_at) VALUES(?,?,?,?,?,?);",
            .{},
            .{ blob(&issue_id), blob(&project_id), title, body, @tagName(state), now_ms },
        );

        try s.appendEventLocked(event_id, issue_id, null, .{ .kind = kind, .actor = actor }, "", now_ms);
        try s.setStateRow(issue_id, state, event_id);

        try s.db.exec("RELEASE create_issue;", .{}, .{});
        return state;
    }

    /// The only way state changes. Appends the event, replays it, and writes the derived
    /// state in one transaction — an illegal transition rolls back rather than leaving an
    /// event the projection disagrees with.
    pub fn appendEvent(
        s: *Store,
        event_id: Id,
        issue_id: Id,
        run_id: ?Id,
        event: model.Event,
        payload: []const u8,
        now_ms: i64,
    ) !model.Issue.State {
        const current = (try s.issueState(issue_id)) orelse return error.NoSuchIssue;

        try s.db.exec("SAVEPOINT append_event;", .{}, .{});
        errdefer s.execScript("ROLLBACK TO append_event; RELEASE append_event;") catch {};

        try s.appendEventLocked(event_id, issue_id, run_id, event, payload, now_ms);

        const next = switch (replay.apply(current, event)) {
            .moved => |n| n,
            .unchanged => current,
            .illegal => return error.IllegalTransition,
        };
        try s.setStateRow(issue_id, next, event_id);

        try s.db.exec("RELEASE append_event;", .{}, .{});
        return next;
    }

    /// An explicit outer transaction, for callers applying several writes that must land
    /// or vanish together — a triage buffer, a memory review. The individual writers use
    /// savepoints, so they nest under this without ceremony.
    pub fn begin(s: *Store) !void {
        try s.db.exec("BEGIN;", .{}, .{});
    }

    /// Commits the outer transaction opened by `begin`.
    pub fn commit(s: *Store) !void {
        try s.db.exec("COMMIT;", .{}, .{});
    }

    /// Never fails: a rollback that cannot run means the transaction is already gone.
    pub fn rollback(s: *Store) void {
        s.db.exec("ROLLBACK;", .{}, .{}) catch {};
    }

    pub const IssueRow = struct {
        id: Id,
        title: []const u8,
        body: []const u8,
        state: model.Issue.State,
        last_event_id: ?Id,
        created_at: i64,
    };

    /// The column shape of `IssueRow`; `state` arrives as the text sqlite stores and is
    /// parsed on the way out.
    const IssueColumns = struct {
        id: Id,
        title: []const u8,
        body: []const u8,
        state: []const u8,
        last_event_id: ?Id,
        created_at: i64,
    };

    fn issueRow(row: IssueColumns) IssueRow {
        return .{
            .id = row.id,
            .title = row.title,
            .body = row.body,
            .state = model.Issue.State.parse(row.state) orelse .open,
            .last_event_id = row.last_event_id,
            .created_at = row.created_at,
        };
    }

    /// One entry in an issue's history.
    ///
    /// `payload` carries whatever the kind needs: the comment text, the archive reason,
    /// the new title, the commit message. It is opaque to the store — the applier writes
    /// it and the reader displays it.
    pub const EventRow = struct {
        id: Id,
        kind: model.Event.Kind,
        actor: model.Event.Actor,
        payload: []const u8,
        created_at: i64,
        /// Set only when the event happened inside a run, which is what distinguishes an
        /// agent's comment from one typed on the host.
        run_id: ?Id,
    };

    const EventColumns = struct {
        id: Id,
        kind: []const u8,
        actor: []const u8,
        payload: []const u8,
        created_at: i64,
        run_id: ?Id,
    };

    /// An issue's events, oldest first.
    ///
    /// Nothing has ever read this table. It has been appended to since the beginning —
    /// it is the append-only log the whole design rests on — but every consumer so far
    /// has used `issues.state`, which is a *cache* of replaying it. Making it readable is
    /// what turns "the state changed" into "the state changed, by whom, and why".
    ///
    /// Ordered by id: those are UUIDv7, so id order is time order without a sort key and
    /// without trusting a clock that two writers might disagree about.
    pub fn listEvents(s: *Store, arena: std.mem.Allocator, issue_id: Id) ![]EventRow {
        var stmt = try s.db.prepare(
            "SELECT id, kind, actor, payload, created_at, run_id FROM events " ++
                "WHERE issue_id = ? ORDER BY id;",
        );
        defer stmt.deinit();

        const columns = try stmt.all(EventColumns, arena, .{}, .{blob(&issue_id)});
        const rows = try arena.alloc(EventRow, columns.len);
        for (columns, rows) |row, *out| out.* = .{
            .id = row.id,
            .kind = std.meta.stringToEnum(model.Event.Kind, row.kind) orelse .commented,
            .actor = std.meta.stringToEnum(model.Event.Actor, row.actor) orelse .human,
            .payload = row.payload,
            .created_at = row.created_at,
            .run_id = row.run_id,
        };
        return rows;
    }

    /// `state_filter` of null means every state. Ordered by id, which is UUIDv7, so this
    /// is creation order without a sort key.
    pub fn listIssues(
        s: *Store,
        arena: std.mem.Allocator,
        project_id: Id,
        state_filter: ?model.Issue.State,
    ) ![]IssueRow {
        const columns = if (state_filter) |state| blk: {
            var stmt = try s.db.prepare(
                "SELECT id, title, body, state, last_event_id, created_at FROM issues " ++
                    "WHERE project_id = ? AND state = ? ORDER BY id;",
            );
            defer stmt.deinit();
            break :blk try stmt.all(IssueColumns, arena, .{}, .{ blob(&project_id), @tagName(state) });
        } else blk: {
            var stmt = try s.db.prepare(
                "SELECT id, title, body, state, last_event_id, created_at FROM issues " ++
                    "WHERE project_id = ? ORDER BY id;",
            );
            defer stmt.deinit();
            break :blk try stmt.all(IssueColumns, arena, .{}, .{blob(&project_id)});
        };

        const rows = try arena.alloc(IssueRow, columns.len);
        for (columns, rows) |row, *out| out.* = issueRow(row);
        return rows;
    }

    /// One issue by exact id, or null. The returned row's strings are copied into
    /// `arena` and live as long as it does.
    pub fn getIssue(s: *Store, arena: std.mem.Allocator, issue_id: Id) !?IssueRow {
        const row = try s.db.oneAlloc(
            struct {
                title: []const u8,
                body: []const u8,
                state: []const u8,
                last_event_id: ?Id,
                created_at: i64,
            },
            arena,
            "SELECT title, body, state, last_event_id, created_at FROM issues WHERE id = ?;",
            .{},
            .{blob(&issue_id)},
        ) orelse return null;

        return issueRow(.{
            .id = issue_id,
            .title = row.title,
            .body = row.body,
            .state = row.state,
            .last_event_id = row.last_event_id,
            .created_at = row.created_at,
        });
    }

    /// Title and body edits, with the optimistic-concurrency check.
    pub fn editIssue(
        s: *Store,
        event_id: Id,
        issue_id: Id,
        title: ?[]const u8,
        body: ?[]const u8,
        expected_last_event: ?Id,
        actor: model.Event.Actor,
        now_ms: i64,
    ) !void {
        const current = (try s.issueState(issue_id)) orelse return error.NoSuchIssue;

        if (expected_last_event) |expected| {
            const actual = try s.lastEventId(issue_id);
            if (actual == null or !std.mem.eql(u8, &actual.?, &expected)) return error.Conflict;
        }

        const kind: model.Event.Kind = if (title != null and body == null) .renamed else .edited;
        switch (replay.apply(current, .{ .kind = kind, .actor = actor })) {
            .unchanged => {},
            else => return error.IllegalTransition,
        }

        try s.db.exec("SAVEPOINT edit_issue;", .{}, .{});
        errdefer s.execScript("ROLLBACK TO edit_issue; RELEASE edit_issue;") catch {};

        try s.appendEventLocked(event_id, issue_id, null, .{ .kind = kind, .actor = actor }, "", now_ms);

        if (title) |t| {
            try s.db.exec("UPDATE issues SET title = ? WHERE id = ?;", .{}, .{ t, blob(&issue_id) });
        }
        if (body) |b| {
            try s.db.exec("UPDATE issues SET body = ? WHERE id = ?;", .{}, .{ b, blob(&issue_id) });
        }

        try s.db.exec(
            "UPDATE issues SET last_event_id = ? WHERE id = ?;",
            .{},
            .{ blob(&event_id), blob(&issue_id) },
        );

        try s.db.exec("RELEASE edit_issue;", .{}, .{});
    }

    /// The issue's current (projected) state, or null when no such issue exists.
    pub fn issueState(s: *Store, issue_id: Id) !?model.Issue.State {
        const text = try s.db.one(
            [31:0]u8,
            "SELECT state FROM issues WHERE id = ?;",
            .{},
            .{blob(&issue_id)},
        ) orelse return null;
        return model.Issue.State.parse(std.mem.sliceTo(&text, 0));
    }

    /// The issue's optimistic-concurrency token: the id of the last event applied to it,
    /// or null when the issue is missing or has no events yet.
    pub fn lastEventId(s: *Store, issue_id: Id) !?Id {
        const row = try s.db.one(
            struct { last_event_id: ?Id },
            "SELECT last_event_id FROM issues WHERE id = ?;",
            .{},
            .{blob(&issue_id)},
        ) orelse return null;
        return row.last_event_id;
    }

    /// How many events the issue's log holds.
    pub fn countEvents(s: *Store, issue_id: Id) !i64 {
        return (try s.db.one(
            i64,
            "SELECT count(*) FROM events WHERE issue_id = ?;",
            .{},
            .{blob(&issue_id)},
        )) orelse 0;
    }

    fn appendEventLocked(
        s: *Store,
        event_id: Id,
        issue_id: Id,
        run_id: ?Id,
        event: model.Event,
        payload: []const u8,
        now_ms: i64,
    ) !void {
        const run: ?sqlite.Blob = if (run_id) |*r| blob(r) else null;
        try s.db.exec(
            "INSERT INTO events(id, issue_id, run_id, actor, kind, payload, created_at) VALUES(?,?,?,?,?,?,?);",
            .{},
            .{
                blob(&event_id),
                blob(&issue_id),
                run,
                @tagName(event.actor),
                @tagName(event.kind),
                payload,
                now_ms,
            },
        );
    }

    /// Private, and called only from the two functions above, both of which reached it by
    /// replaying an event. This is the single `SET state` in the codebase.
    fn setStateRow(s: *Store, issue_id: Id, state: model.Issue.State, event_id: Id) !void {
        try s.db.exec(
            "UPDATE issues SET state = ?, last_event_id = ? WHERE id = ?;",
            .{},
            .{ @tagName(state), blob(&event_id), blob(&issue_id) },
        );
    }

    pub const RunRow = struct {
        id: Id,
        issue_id: Id,
        project_id: Id,
        branch: []const u8,
        state: model.Run.State,
        started_at: i64,
        ended_at: ?i64,
    };

    /// Starting a run also moves the issue to `in_progress` — dispatching work and saying
    /// so are the same act, and leaving them separate invites a run whose issue still
    /// reads `open`.
    pub fn startRun(
        s: *Store,
        run_id: Id,
        issue_id: Id,
        project_id: Id,
        branch: []const u8,
        token_hash: []const u8,
        event_id: Id,
        now_ms: i64,
    ) !void {
        try s.db.exec("SAVEPOINT start_run;", .{}, .{});
        errdefer s.execScript("ROLLBACK TO start_run; RELEASE start_run;") catch {};

        try s.db.exec(
            "INSERT INTO runs(id, issue_id, project_id, branch, token_hash, state, started_at) " ++
                "VALUES(?,?,?,?,?,?,?);",
            .{},
            .{
                blob(&run_id),
                blob(&issue_id),
                blob(&project_id),
                branch,
                sqlite.Blob{ .data = token_hash },
                @tagName(model.Run.State.active),
                now_ms,
            },
        );

        const current = (try s.issueState(issue_id)) orelse return error.NoSuchIssue;
        const event = model.Event{ .kind = .state_changed, .actor = .human, .to = .in_progress };
        switch (replay.apply(current, event)) {
            .moved => |next| {
                try s.appendEventLocked(event_id, issue_id, run_id, event, "", now_ms);
                try s.setStateRow(issue_id, next, event_id);
            },
            .unchanged => {},
            .illegal => return error.IllegalTransition,
        }

        try s.db.exec("RELEASE start_run;", .{}, .{});
    }

    /// `ended` means the user quit; `abandoned` means something broke. Keeping them apart
    /// is the point — the dashboard should be able to say which.
    pub fn finishRun(s: *Store, run_id: Id, state: model.Run.State, now_ms: i64) !void {
        try s.db.exec(
            "UPDATE runs SET state = ?, ended_at = ?, token_hash = NULL " ++
                "WHERE id = ? AND state = 'active';",
            .{},
            .{ @tagName(state), now_ms, blob(&run_id) },
        );
    }

    pub const ActiveRun = struct {
        run_id: Id,
        issue_id: Id,
        project_id: Id,
        branch: []const u8,
        token_hash: []const u8,
    };

    /// Every live run, which is exactly the set a token can resolve against.
    pub fn activeRuns(s: *Store, arena: std.mem.Allocator) ![]ActiveRun {
        var stmt = try s.db.prepare(
            "SELECT id, issue_id, project_id, branch, token_hash FROM runs " ++
                "WHERE state = 'active' AND token_hash IS NOT NULL ORDER BY id;",
        );
        defer stmt.deinit();

        const columns = try stmt.all(struct {
            run_id: Id,
            issue_id: Id,
            project_id: Id,
            branch: []const u8,
            token_hash: sqlite.Blob,
        }, arena, .{}, .{});

        const rows = try arena.alloc(ActiveRun, columns.len);
        for (columns, rows) |row, *out| out.* = .{
            .run_id = row.run_id,
            .issue_id = row.issue_id,
            .project_id = row.project_id,
            .branch = row.branch,
            .token_hash = row.token_hash.data,
        };
        return rows;
    }

    /// The refusal rule for `run start`: one run per project at a time, because the
    /// replica keeps one working tree.
    pub fn activeRunForProject(s: *Store, arena: std.mem.Allocator, project_id: Id) !?ActiveRun {
        const all = try s.activeRuns(arena);
        for (all) |run| {
            if (std.mem.eql(u8, &run.project_id, &project_id)) return run;
        }
        return null;
    }

    /// The project's most recent runs, newest first (descending UUIDv7 id), at most
    /// `limit` of them. Rows are copied into `arena`, which owns them.
    pub fn listRuns(s: *Store, arena: std.mem.Allocator, project_id: Id, limit: u32) ![]RunRow {
        var stmt = try s.db.prepare(
            "SELECT id, issue_id, project_id, branch, state, started_at, ended_at FROM runs " ++
                "WHERE project_id = ? ORDER BY id DESC LIMIT ?;",
        );
        defer stmt.deinit();

        const columns = try stmt.all(struct {
            id: Id,
            issue_id: Id,
            project_id: Id,
            branch: []const u8,
            state: []const u8,
            started_at: i64,
            ended_at: ?i64,
        }, arena, .{}, .{ blob(&project_id), limit });

        const rows = try arena.alloc(RunRow, columns.len);
        for (columns, rows) |row, *out| out.* = .{
            .id = row.id,
            .issue_id = row.issue_id,
            .project_id = row.project_id,
            .branch = row.branch,
            .state = std.meta.stringToEnum(model.Run.State, row.state) orelse .abandoned,
            .started_at = row.started_at,
            .ended_at = row.ended_at,
        };
        return rows;
    }

    /// Anything still marked active whose container is gone is `abandoned`.
    pub fn reconcileRuns(
        s: *Store,
        arena: std.mem.Allocator,
        live_container_names: []const []const u8,
        now_ms: i64,
    ) !usize {
        const active = try s.activeRuns(arena);
        var abandoned: usize = 0;
        for (active) |run| {
            const name = try containerName(arena, run.run_id);
            var found = false;
            for (live_container_names) |live| {
                if (std.mem.eql(u8, live, name)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            try s.finishRun(run.run_id, .abandoned, now_ms);
            abandoned += 1;
        }
        return abandoned;
    }

    pub const MemoryRow = struct {
        id: Id,
        state: model.Memory.State,
        body: []const u8,
        /// Newline-separated repo-relative paths.
        anchors: []const u8,
        origin_issue_id: ?Id,
    };

    const MemoryColumns = struct {
        id: Id,
        state: []const u8,
        body: []const u8,
        anchors: []const u8,
        origin_issue_id: ?Id,
    };

    /// Agent-written and never injected until a human activates it. The agent does not see
    /// it again after proposing it.
    pub fn proposeMemory(
        s: *Store,
        memory_id: Id,
        project_id: Id,
        body: []const u8,
        anchors: []const u8,
        origin_issue_id: ?Id,
        now_ms: i64,
    ) !void {
        const origin: ?sqlite.Blob = if (origin_issue_id) |*o| blob(o) else null;
        try s.db.exec(
            "INSERT INTO memories(id, project_id, state, body, anchors, origin_issue_id, created_at) " ++
                "VALUES(?,?,?,?,?,?,?);",
            .{},
            .{
                blob(&memory_id),
                blob(&project_id),
                @tagName(model.Memory.State.proposed),
                body,
                anchors,
                origin,
                now_ms,
            },
        );
    }

    /// The project's memories in creation order; `state` of null means every state.
    pub fn listMemories(
        s: *Store,
        arena: std.mem.Allocator,
        project_id: Id,
        state: ?model.Memory.State,
    ) ![]MemoryRow {
        const columns = if (state) |st| blk: {
            var stmt = try s.db.prepare(
                "SELECT id, state, body, anchors, origin_issue_id FROM memories " ++
                    "WHERE project_id = ? AND state = ? ORDER BY id;",
            );
            defer stmt.deinit();
            break :blk try stmt.all(MemoryColumns, arena, .{}, .{ blob(&project_id), @tagName(st) });
        } else blk: {
            var stmt = try s.db.prepare(
                "SELECT id, state, body, anchors, origin_issue_id FROM memories " ++
                    "WHERE project_id = ? ORDER BY id;",
            );
            defer stmt.deinit();
            break :blk try stmt.all(MemoryColumns, arena, .{}, .{blob(&project_id)});
        };

        const rows = try arena.alloc(MemoryRow, columns.len);
        for (columns, rows) |row, *out| out.* = .{
            .id = row.id,
            .state = std.meta.stringToEnum(model.Memory.State, row.state) orelse .proposed,
            .body = row.body,
            .anchors = row.anchors,
            .origin_issue_id = row.origin_issue_id,
        };
        return rows;
    }

    /// How many memories are active — the number the cap in memory.zig is checked
    /// against.
    pub fn countActiveMemories(s: *Store, project_id: Id) !i64 {
        return (try s.db.one(
            i64,
            "SELECT count(*) FROM memories WHERE project_id = ? AND state = 'active';",
            .{},
            .{blob(&project_id)},
        )) orelse 0;
    }

    /// Moves a memory between states. The hard cap is enforced by the caller, which has
    /// the whole review buffer in view and can tell an accept that frees a slot from one
    /// that does not.
    pub fn setMemoryState(s: *Store, memory_id: Id, state: model.Memory.State, now_ms: i64) !void {
        try s.db.exec(
            "UPDATE memories SET state = ?, reviewed_at = ? WHERE id = ?;",
            .{},
            .{ @tagName(state), now_ms, blob(&memory_id) },
        );
    }

    /// Overwrites a memory's body and anchors with what the reviewer left in the buffer.
    pub fn editMemory(s: *Store, memory_id: Id, body: []const u8, anchors: []const u8, now_ms: i64) !void {
        try s.db.exec(
            "UPDATE memories SET body = ?, anchors = ?, reviewed_at = ? WHERE id = ?;",
            .{},
            .{ body, anchors, now_ms, blob(&memory_id) },
        );
    }
};

/// Derivable in both directions without a lookup table, so the world-model poll can map
/// `podman ps` output straight onto runs.
pub fn containerName(arena: std.mem.Allocator, run_id: Id) ![]const u8 {
    return std.fmt.allocPrint(arena, "capsule-{s}", .{ids.toHex(run_id)[0..12]});
}

const testing = std.testing;

fn seeded(n: u8) Id {
    var id: Id = undefined;
    @memset(&id, n);
    return id;
}

fn freshStore() !Store {
    return Store.open(":memory:");
}

test "the schema applies cleanly to an empty database" {
    var s = try freshStore();
    defer s.close();
    try testing.expectEqual(@as(i64, 0), try s.countProjects());
}

test "a project round-trips by canonical path" {
    var s = try freshStore();
    defer s.close();

    const pid = seeded(1);
    try s.addProject(pid, "/real/path", "default", 1000);
    try testing.expectEqual(pid, (try s.findProject("/real/path")).?);
    try testing.expectEqual(@as(?Id, null), try s.findProject("/other"));
    try testing.expectEqual(@as(i64, 1), try s.countProjects());
}

test "registering the same path twice is refused" {
    var s = try freshStore();
    defer s.close();
    try s.addProject(seeded(1), "/p", "default", 1000);
    try testing.expectError(error.SQLiteConstraint, s.addProject(seeded(2), "/p", "default", 1001));
}

test "a human-created issue opens; an agent-filed one is proposed" {
    var s = try freshStore();
    defer s.close();
    const pid = seeded(1);
    try s.addProject(pid, "/p", "default", 1000);

    try testing.expectEqual(
        model.Issue.State.open,
        try s.createIssue(seeded(10), pid, "t", "b", .human, seeded(11), 1001),
    );
    try testing.expectEqual(
        model.Issue.State.proposed,
        try s.createIssue(seeded(20), pid, "t", "b", .agent, seeded(21), 1002),
    );
}

test "state moves only by appending an event, and the projection follows" {
    var s = try freshStore();
    defer s.close();
    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);

    const next = try s.appendEvent(
        seeded(12),
        issue,
        null,
        .{ .kind = .state_changed, .actor = .agent, .to = .in_progress },
        "",
        1002,
    );
    try testing.expectEqual(model.Issue.State.in_progress, next);
    try testing.expectEqual(model.Issue.State.in_progress, (try s.issueState(issue)).?);
    try testing.expectEqual(seeded(12), (try s.lastEventId(issue)).?);
}

test "an illegal transition rolls back and leaves no event behind" {
    var s = try freshStore();
    defer s.close();
    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);

    const before = try s.countEvents(issue);
    try testing.expectError(error.IllegalTransition, s.appendEvent(
        seeded(13),
        issue,
        null,
        .{ .kind = .state_changed, .actor = .agent, .to = .done },
        "",
        1003,
    ));
    try testing.expectEqual(before, try s.countEvents(issue));
    try testing.expectEqual(model.Issue.State.open, (try s.issueState(issue)).?);
}

test "a comment is recorded without moving the issue" {
    var s = try freshStore();
    defer s.close();
    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);

    const next = try s.appendEvent(
        seeded(14),
        issue,
        null,
        .{ .kind = .commented, .actor = .agent },
        "stuck on the tunnel",
        1004,
    );
    try testing.expectEqual(model.Issue.State.open, next);
    try testing.expectEqual(@as(i64, 2), try s.countEvents(issue));
}

test "the event log reads back as the history it recorded" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);
    _ = try s.appendEvent(seeded(12), issue, null, .{ .kind = .commented, .actor = .human }, "mine", 1002);
    _ = try s.appendEvent(seeded(13), issue, seeded(90), .{ .kind = .commented, .actor = .agent }, "theirs", 1003);

    const events = try s.listEvents(a.allocator(), issue);
    try testing.expectEqual(@as(usize, 3), events.len);

    // Oldest first, by id — UUIDv7, so that is time order without trusting a clock.
    try testing.expectEqual(model.Event.Kind.created, events[0].kind);
    try testing.expectEqualStrings("mine", events[1].payload);
    try testing.expectEqual(model.Event.Actor.human, events[1].actor);
    try testing.expectEqualStrings("theirs", events[2].payload);
    try testing.expectEqual(model.Event.Actor.agent, events[2].actor);

    // The run id is what separates the agent's note from one typed on the host.
    try testing.expectEqual(@as(?Id, null), events[1].run_id);
    try testing.expect(events[2].run_id != null);
}

test "an issue with no events of its own reads as empty, not as an error" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), (try s.listEvents(a.allocator(), seeded(99))).len);
}

test "one issue's log does not include another's" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const pid = seeded(1);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(seeded(10), pid, "one", "", .human, seeded(11), 1001);
    _ = try s.createIssue(seeded(20), pid, "two", "", .human, seeded(21), 1002);
    _ = try s.appendEvent(seeded(22), seeded(20), null, .{ .kind = .commented, .actor = .human }, "on two", 1003);

    const first = try s.listEvents(a.allocator(), seeded(10));
    try testing.expectEqual(@as(usize, 1), first.len);
    for (first) |e| try testing.expect(!std.mem.eql(u8, e.payload, "on two"));
}

test "events for an unknown issue are refused" {
    var s = try freshStore();
    defer s.close();
    try testing.expectError(error.NoSuchIssue, s.appendEvent(
        seeded(15),
        seeded(99),
        null,
        .{ .kind = .commented, .actor = .human },
        "",
        1005,
    ));
}

test "merge is the only route to done, and it is terminal thereafter" {
    var s = try freshStore();
    defer s.close();
    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);

    _ = try s.appendEvent(seeded(16), issue, null, .{ .kind = .merged, .actor = .human }, "", 1006);
    try testing.expectEqual(model.Issue.State.done, (try s.issueState(issue)).?);

    try testing.expectError(error.IllegalTransition, s.appendEvent(
        seeded(17),
        issue,
        null,
        .{ .kind = .reopened, .actor = .human },
        "",
        1007,
    ));
}

test "there is exactly one SET state in this file" {
    const source = @embedFile("store.zig");
    const needle = "UPDATE issues SET state" ++ " = ?";
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, needle));
}

test "issues list by state, and getIssue round-trips the text" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const pid = seeded(1);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(seeded(10), pid, "first", "body one", .human, seeded(11), 1001);
    _ = try s.createIssue(seeded(20), pid, "second", "body two", .agent, seeded(21), 1002);

    const all = try s.listIssues(a.allocator(), pid, null);
    try testing.expectEqual(@as(usize, 2), all.len);

    const open = try s.listIssues(a.allocator(), pid, .open);
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqualStrings("first", open[0].title);

    const proposed = try s.listIssues(a.allocator(), pid, .proposed);
    try testing.expectEqual(@as(usize, 1), proposed.len);
    try testing.expectEqualStrings("second", proposed[0].title);

    const one = (try s.getIssue(a.allocator(), seeded(10))).?;
    try testing.expectEqualStrings("body one", one.body);
    try testing.expectEqual(model.Issue.State.open, one.state);
}

test "an edit writes an event and moves the concurrency token" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);

    try s.editIssue(seeded(12), issue, null, "new body", seeded(11), .human, 1002);
    const row = (try s.getIssue(a.allocator(), issue)).?;
    try testing.expectEqualStrings("new body", row.body);
    try testing.expectEqual(seeded(12), row.last_event_id.?);
    try testing.expectEqual(@as(i64, 2), try s.countEvents(issue));
}

test "a stale concurrency token is refused rather than clobbering" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);
    try s.editIssue(seeded(12), issue, null, "first edit", seeded(11), .human, 1002);

    try testing.expectError(
        error.Conflict,
        s.editIssue(seeded(13), issue, null, "second edit", seeded(11), .human, 1003),
    );
    const row = (try s.getIssue(a.allocator(), issue)).?;
    try testing.expectEqualStrings("first edit", row.body);
}

test "a title-only change is a rename" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "old", "b", .human, seeded(11), 1001);

    try s.editIssue(seeded(12), issue, "new title", null, null, .human, 1002);
    const row = (try s.getIssue(a.allocator(), issue)).?;
    try testing.expectEqualStrings("new title", row.title);
    try testing.expectEqualStrings("b", row.body);
}

test "editing a merged issue is refused: done is terminal" {
    var s = try freshStore();
    defer s.close();
    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);
    _ = try s.appendEvent(seeded(12), issue, null, .{ .kind = .merged, .actor = .human }, "", 1002);

    try testing.expectError(
        error.IllegalTransition,
        s.editIssue(seeded(13), issue, null, "too late", null, .human, 1003),
    );
}

test "getIssue on an unknown id is null, not an error" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqual(@as(?Store.IssueRow, null), try s.getIssue(a.allocator(), seeded(99)));
}

fn withIssue(s: *Store) !struct { project: Id, issue: Id } {
    const pid = seeded(1);
    const issue = seeded(10);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);
    return .{ .project = pid, .issue = issue };
}

test "starting a run moves its issue to in_progress" {
    var s = try freshStore();
    defer s.close();
    const ctx = try withIssue(&s);

    try s.startRun(seeded(30), ctx.issue, ctx.project, "capsule/abc", "hash", seeded(31), 1002);
    try testing.expectEqual(model.Issue.State.in_progress, (try s.issueState(ctx.issue)).?);
}

test "an active run is findable by project, and only one exists" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ctx = try withIssue(&s);

    try testing.expectEqual(
        @as(?Store.ActiveRun, null),
        try s.activeRunForProject(a.allocator(), ctx.project),
    );

    try s.startRun(seeded(30), ctx.issue, ctx.project, "capsule/abc", "hash", seeded(31), 1002);
    const live = (try s.activeRunForProject(a.allocator(), ctx.project)).?;
    try testing.expectEqual(seeded(30), live.run_id);
    try testing.expectEqualStrings("capsule/abc", live.branch);
}

test "ending a run revokes its token by removing it from the active set" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ctx = try withIssue(&s);

    try s.startRun(seeded(30), ctx.issue, ctx.project, "capsule/abc", "secret-hash", seeded(31), 1002);
    try testing.expectEqual(@as(usize, 1), (try s.activeRuns(a.allocator())).len);

    try s.finishRun(seeded(30), .ended, 1003);
    try testing.expectEqual(@as(usize, 0), (try s.activeRuns(a.allocator())).len);
    try testing.expectEqual(
        @as(?Store.ActiveRun, null),
        try s.activeRunForProject(a.allocator(), ctx.project),
    );
}

test "ended and abandoned are kept apart" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ctx = try withIssue(&s);

    try s.startRun(seeded(30), ctx.issue, ctx.project, "capsule/a", "h1", seeded(31), 1002);
    try s.finishRun(seeded(30), .ended, 1003);
    try s.startRun(seeded(40), ctx.issue, ctx.project, "capsule/b", "h2", seeded(41), 1004);
    try s.finishRun(seeded(40), .abandoned, 1005);

    const rows = try s.listRuns(a.allocator(), ctx.project, 10);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(model.Run.State.abandoned, rows[0].state);
    try testing.expectEqual(model.Run.State.ended, rows[1].state);
    try testing.expectEqual(@as(i64, 1005), rows[0].ended_at.?);
}

test "finishing an already-finished run does not resurrect or relabel it" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ctx = try withIssue(&s);

    try s.startRun(seeded(30), ctx.issue, ctx.project, "capsule/a", "h", seeded(31), 1002);
    try s.finishRun(seeded(30), .ended, 1003);
    try s.finishRun(seeded(30), .abandoned, 1004);

    const rows = try s.listRuns(a.allocator(), ctx.project, 10);
    try testing.expectEqual(model.Run.State.ended, rows[0].state);
    try testing.expectEqual(@as(i64, 1003), rows[0].ended_at.?);
}

test "reconcile abandons runs whose container is gone, and spares the ones still up" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const pid = seeded(1);
    try s.addProject(pid, "/p", "default", 1000);
    _ = try s.createIssue(seeded(10), pid, "one", "", .human, seeded(11), 1001);
    _ = try s.createIssue(seeded(20), pid, "two", "", .human, seeded(21), 1001);

    try s.startRun(seeded(30), seeded(10), pid, "capsule/a", "h1", seeded(31), 1002);
    try s.startRun(seeded(40), seeded(20), pid, "capsule/b", "h2", seeded(41), 1003);

    const still_up = try containerName(a.allocator(), seeded(40));
    const abandoned = try s.reconcileRuns(a.allocator(), &.{still_up}, 1004);
    try testing.expectEqual(@as(usize, 1), abandoned);

    const live = try s.activeRuns(a.allocator());
    try testing.expectEqual(@as(usize, 1), live.len);
    try testing.expectEqual(seeded(40), live[0].run_id);
}

test "reconcile with nothing running abandons everything live" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ctx = try withIssue(&s);

    try s.startRun(seeded(30), ctx.issue, ctx.project, "capsule/a", "h", seeded(31), 1002);
    try testing.expectEqual(@as(usize, 1), try s.reconcileRuns(a.allocator(), &.{}, 1003));
    try testing.expectEqual(@as(usize, 0), (try s.activeRuns(a.allocator())).len);
}

test "the container name is derivable from the run id in both directions" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const name = try containerName(a.allocator(), seeded(0xab));
    try testing.expect(std.mem.startsWith(u8, name, "capsule-"));
    try testing.expectEqual(@as(usize, "capsule-".len + 12), name.len);
    try testing.expectEqualStrings(name, try containerName(a.allocator(), seeded(0xab)));
}

test "removeProject refuses with issues, and force takes the whole tree with it" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const pid = seeded(1);
    try s.addProject(pid, "/p", "default", 1000);
    const issue = seeded(10);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);
    try s.startRun(seeded(30), issue, pid, "capsule/a", "h", seeded(31), 1002);
    try s.proposeMemory(seeded(40), pid, "remember", "", null, 1003);

    try testing.expectError(error.HasIssues, s.removeProject(pid, false));

    try s.removeProject(pid, true);
    try testing.expectEqual(@as(i64, 0), try s.countProjects());
    try testing.expectEqual(@as(i64, 0), try s.countIssues(pid));
    try testing.expectEqual(@as(usize, 0), (try s.activeRuns(a.allocator())).len);
    try testing.expectEqual(@as(usize, 0), (try s.listMemories(a.allocator(), pid, null)).len);
}

test "a memory's body and anchors are editable, its state untouched" {
    var s = try freshStore();
    defer s.close();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    const pid = seeded(1);
    try s.addProject(pid, "/p", "default", 1000);
    try s.proposeMemory(seeded(40), pid, "rough wording", "old.zig", null, 1001);

    try s.editMemory(seeded(40), "tight wording", "new.zig\nother.zig", 1002);

    const rows = try s.listMemories(a.allocator(), pid, .proposed);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("tight wording", rows[0].body);
    try testing.expectEqualStrings("new.zig\nother.zig", rows[0].anchors);
}

test "writers nest under an explicit outer transaction and roll back together" {
    var s = try freshStore();
    defer s.close();

    const pid = seeded(1);
    try s.addProject(pid, "/p", "default", 1000);
    const issue = seeded(10);
    _ = try s.createIssue(issue, pid, "t", "b", .human, seeded(11), 1001);
    const before = try s.countEvents(issue);

    try s.begin();
    _ = try s.appendEvent(seeded(12), issue, null, .{ .kind = .commented, .actor = .human }, "one", 1002);
    _ = try s.appendEvent(seeded(13), issue, null, .{ .kind = .commented, .actor = .human }, "two", 1003);
    s.rollback();

    try testing.expectEqual(before, try s.countEvents(issue));

    try s.begin();
    _ = try s.appendEvent(seeded(14), issue, null, .{ .kind = .commented, .actor = .human }, "kept", 1004);
    try s.commit();
    try testing.expectEqual(before + 1, try s.countEvents(issue));
}
