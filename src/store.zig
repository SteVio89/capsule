//! The only file that knows SQL.
//!
//! The load-bearing rule: there is no public setter for an issue's state. Command code
//! appends an event and the applier derives the new state in the same transaction. A
//! direct `UPDATE issues SET state = …` anywhere else would erode the trust posture
//! silently, so there is exactly one of those in this file and a test that counts them.
//!
//! `runs.state` is not the same kind of thing — it is an ordinary column, not a replay of
//! anything — and is written directly.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const model = @import("model.zig");
const replay = @import("replay.zig");
const ids = @import("id.zig");

const Id = ids.Id;

pub const schema = @embedFile("schema.sql");

pub const Error = sqlite.Error ||
    error{ IllegalTransition, NoSuchIssue, HasIssues, Conflict } ||
    std.mem.Allocator.Error;

pub const Store = struct {
    db: sqlite.Db,

    /// Opens (creating if needed) the database at `path` and applies the schema, which
    /// is written to be idempotent. `:memory:` works and is what the tests use.
    pub fn open(path: [:0]const u8) Error!Store {
        var db = try sqlite.Db.open(path);
        errdefer db.close();
        try db.exec(schema);
        return .{ .db = db };
    }

    /// Closes the underlying connection. The store is unusable afterwards.
    pub fn close(s: *Store) void {
        s.db.close();
    }

    // ------------------------------------------------------------ projects

    /// Registers a project. `canonical_path` is unique — registering the same path twice
    /// is `error.Constraint`, not an upsert.
    pub fn addProject(s: *Store, id: Id, canonical_path: []const u8, profile: []const u8, now_ms: i64) Error!void {
        var stmt = try s.db.prepare(
            "INSERT INTO projects(id, canonical_path, profile, created_at) VALUES(?,?,?,?);",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &id);
        try stmt.bindText(2, canonical_path);
        try stmt.bindText(3, profile);
        try stmt.bindInt(4, now_ms);
        _ = try stmt.step();
    }

    /// The project id registered under exactly this canonical path, or null. No path
    /// normalisation happens here — the caller canonicalises before asking.
    pub fn findProject(s: *Store, canonical_path: []const u8) Error!?Id {
        var stmt = try s.db.prepare("SELECT id FROM projects WHERE canonical_path = ?;");
        defer stmt.finalize();
        try stmt.bindText(1, canonical_path);
        if (!try stmt.step()) return null;
        const blob = stmt.columnBlob(0);
        if (blob.len != @sizeOf(Id)) return null;
        var out: Id = undefined;
        @memcpy(&out, blob);
        return out;
    }

    pub const ProjectRow = struct {
        id: Id,
        canonical_path: []const u8,
        profile: []const u8,
    };

    /// Rows are copied into `arena` rather than handed out as sqlite's own buffers, which
    /// the next `step` would invalidate underneath the caller.
    pub fn listProjects(s: *Store, arena: std.mem.Allocator) ![]ProjectRow {
        var stmt = try s.db.prepare("SELECT id, canonical_path, profile FROM projects ORDER BY id;");
        defer stmt.finalize();

        var rows: std.ArrayList(ProjectRow) = .empty;
        while (try stmt.step()) {
            const blob = stmt.columnBlob(0);
            if (blob.len != @sizeOf(Id)) continue;
            var id: Id = undefined;
            @memcpy(&id, blob);
            try rows.append(arena, .{
                .id = id,
                .canonical_path = try arena.dupe(u8, stmt.columnText(1)),
                .profile = try arena.dupe(u8, stmt.columnText(2)),
            });
        }
        return rows.toOwnedSlice(arena);
    }

    /// The project's profile name, copied into `arena` (the caller's arena owns it), or
    /// null when no such project exists.
    pub fn projectProfile(s: *Store, arena: std.mem.Allocator, id: Id) Error!?[]const u8 {
        var stmt = try s.db.prepare("SELECT profile FROM projects WHERE id = ?;");
        defer stmt.finalize();
        try stmt.bindBlob(1, &id);
        if (!try stmt.step()) return null;
        return arena.dupe(u8, stmt.columnText(0)) catch return error.SqliteError;
    }

    /// Points the project at a different profile. Writing to a nonexistent project is
    /// not an error — zero rows simply match.
    pub fn setProjectProfile(s: *Store, id: Id, profile: []const u8) Error!void {
        var stmt = try s.db.prepare("UPDATE projects SET profile = ? WHERE id = ?;");
        defer stmt.finalize();
        try stmt.bindText(1, profile);
        try stmt.bindBlob(2, &id);
        _ = try stmt.step();
    }

    /// How many issues the project has, in any state.
    pub fn countIssues(s: *Store, project_id: Id) Error!i64 {
        var stmt = try s.db.prepare("SELECT count(*) FROM issues WHERE project_id = ?;");
        defer stmt.finalize();
        try stmt.bindBlob(1, &project_id);
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    /// Refuses while issues exist unless forced. A typo'd `rm` is the one failure here
    /// with no undo, and the events are append-only precisely so they are not disposable.
    ///
    /// Forcing removes the project's issues, events, runs, and memories with it, in one
    /// savepoint. Deleting the project row alone can never work — the children's foreign
    /// keys reject it, which made `--force` a promise the store could not keep.
    pub fn removeProject(s: *Store, id: Id, force: bool) Error!void {
        if (!force and try s.countIssues(id) > 0) return error.HasIssues;

        try s.db.exec("SAVEPOINT rm_project;");
        errdefer s.db.exec("ROLLBACK TO rm_project; RELEASE rm_project;") catch {};

        const child_deletes = [_][:0]const u8{
            "DELETE FROM events WHERE issue_id IN (SELECT id FROM issues WHERE project_id = ?);",
            "DELETE FROM runs WHERE project_id = ?;",
            "DELETE FROM memories WHERE project_id = ?;",
            "DELETE FROM issues WHERE project_id = ?;",
            "DELETE FROM projects WHERE id = ?;",
        };
        for (child_deletes) |sql| {
            var stmt = try s.db.prepare(sql);
            defer stmt.finalize();
            try stmt.bindBlob(1, &id);
            _ = try stmt.step();
        }

        try s.db.exec("RELEASE rm_project;");
    }

    /// How many projects are registered.
    pub fn countProjects(s: *Store) Error!i64 {
        var stmt = try s.db.prepare("SELECT count(*) FROM projects;");
        defer stmt.finalize();
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    // ------------------------------------------------------------ issues and events

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
    ) Error!model.Issue.State {
        const kind: model.Event.Kind = if (actor == .agent) .filed_by_agent else .created;
        const outcome = replay.apply(null, .{ .kind = kind, .actor = actor });
        const state = switch (outcome) {
            .moved => |next| next,
            else => return error.IllegalTransition,
        };

        try s.db.exec("SAVEPOINT create_issue;");
        errdefer s.db.exec("ROLLBACK TO create_issue; RELEASE create_issue;") catch {};

        var ins = try s.db.prepare(
            "INSERT INTO issues(id, project_id, title, body, state, created_at) VALUES(?,?,?,?,?,?);",
        );
        defer ins.finalize();
        try ins.bindBlob(1, &issue_id);
        try ins.bindBlob(2, &project_id);
        try ins.bindText(3, title);
        try ins.bindText(4, body);
        try ins.bindText(5, @tagName(state));
        try ins.bindInt(6, now_ms);
        _ = try ins.step();

        try s.appendEventLocked(event_id, issue_id, null, .{ .kind = kind, .actor = actor }, "", now_ms);
        try s.setStateRow(issue_id, state, event_id);

        try s.db.exec("RELEASE create_issue;");
        return state;
    }

    /// The only way state changes. Appends the event, replays it, and writes the derived
    /// state in one transaction — an illegal transition rolls back rather than leaving an
    /// event the projection disagrees with.
    ///
    /// A savepoint rather than BEGIN, here and in every writer: standalone it behaves
    /// exactly like a transaction, and inside `begin`/`commit` it nests instead of
    /// erroring, which is what lets triage apply a whole buffer atomically.
    pub fn appendEvent(
        s: *Store,
        event_id: Id,
        issue_id: Id,
        run_id: ?Id,
        event: model.Event,
        payload: []const u8,
        now_ms: i64,
    ) Error!model.Issue.State {
        const current = (try s.issueState(issue_id)) orelse return error.NoSuchIssue;

        try s.db.exec("SAVEPOINT append_event;");
        errdefer s.db.exec("ROLLBACK TO append_event; RELEASE append_event;") catch {};

        try s.appendEventLocked(event_id, issue_id, run_id, event, payload, now_ms);

        const next = switch (replay.apply(current, event)) {
            .moved => |n| n,
            .unchanged => current,
            .illegal => return error.IllegalTransition,
        };
        try s.setStateRow(issue_id, next, event_id);

        try s.db.exec("RELEASE append_event;");
        return next;
    }

    /// An explicit outer transaction, for callers applying several writes that must land
    /// or vanish together — a triage buffer, a memory review. The individual writers use
    /// savepoints, so they nest under this without ceremony.
    pub fn begin(s: *Store) Error!void {
        try s.db.exec("BEGIN;");
    }

    /// Commits the outer transaction opened by `begin`.
    pub fn commit(s: *Store) Error!void {
        try s.db.exec("COMMIT;");
    }

    /// Never fails: a rollback that cannot run means the transaction is already gone.
    pub fn rollback(s: *Store) void {
        s.db.exec("ROLLBACK;") catch {};
    }

    pub const IssueRow = struct {
        id: Id,
        title: []const u8,
        body: []const u8,
        state: model.Issue.State,
        last_event_id: ?Id,
    };

    /// `state_filter` of null means every state. Ordered by id, which is UUIDv7, so this
    /// is creation order without a sort key.
    pub fn listIssues(
        s: *Store,
        arena: std.mem.Allocator,
        project_id: Id,
        state_filter: ?model.Issue.State,
    ) ![]IssueRow {
        var stmt = if (state_filter) |_|
            try s.db.prepare(
                "SELECT id, title, body, state, last_event_id FROM issues " ++
                    "WHERE project_id = ? AND state = ? ORDER BY id;",
            )
        else
            try s.db.prepare(
                "SELECT id, title, body, state, last_event_id FROM issues " ++
                    "WHERE project_id = ? ORDER BY id;",
            );
        defer stmt.finalize();

        try stmt.bindBlob(1, &project_id);
        if (state_filter) |state| try stmt.bindText(2, @tagName(state));

        var rows: std.ArrayList(IssueRow) = .empty;
        while (try stmt.step()) {
            const id_blob = stmt.columnBlob(0);
            if (id_blob.len != @sizeOf(Id)) continue;
            var id: Id = undefined;
            @memcpy(&id, id_blob);

            var last: ?Id = null;
            if (!stmt.isNull(4)) {
                const blob = stmt.columnBlob(4);
                if (blob.len == @sizeOf(Id)) {
                    var l: Id = undefined;
                    @memcpy(&l, blob);
                    last = l;
                }
            }
            try rows.append(arena, .{
                .id = id,
                .title = try arena.dupe(u8, stmt.columnText(1)),
                .body = try arena.dupe(u8, stmt.columnText(2)),
                .state = model.Issue.State.parse(stmt.columnText(3)) orelse .open,
                .last_event_id = last,
            });
        }
        return rows.toOwnedSlice(arena);
    }

    /// One issue by exact id, or null. The returned row's strings are copied into
    /// `arena` and live as long as it does.
    pub fn getIssue(s: *Store, arena: std.mem.Allocator, issue_id: Id) !?IssueRow {
        var stmt = try s.db.prepare(
            "SELECT title, body, state, last_event_id FROM issues WHERE id = ?;",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &issue_id);
        if (!try stmt.step()) return null;

        var last: ?Id = null;
        if (!stmt.isNull(3)) {
            const blob = stmt.columnBlob(3);
            if (blob.len == @sizeOf(Id)) {
                var l: Id = undefined;
                @memcpy(&l, blob);
                last = l;
            }
        }
        return .{
            .id = issue_id,
            .title = try arena.dupe(u8, stmt.columnText(0)),
            .body = try arena.dupe(u8, stmt.columnText(1)),
            .state = model.Issue.State.parse(stmt.columnText(2)) orelse .open,
            .last_event_id = last,
        };
    }

    /// Title and body edits, with the optimistic-concurrency check.
    ///
    /// `expected_last_event` is read when the editor is spawned and compared before the
    /// write. The agent cannot cause a conflict — it has no description-write tool — but a
    /// user with three terminals open can, and silently clobbering one of them would be
    /// the worst outcome.
    pub fn editIssue(
        s: *Store,
        event_id: Id,
        issue_id: Id,
        title: ?[]const u8,
        body: ?[]const u8,
        expected_last_event: ?Id,
        actor: model.Event.Actor,
        now_ms: i64,
    ) Error!void {
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

        try s.db.exec("SAVEPOINT edit_issue;");
        errdefer s.db.exec("ROLLBACK TO edit_issue; RELEASE edit_issue;") catch {};

        try s.appendEventLocked(event_id, issue_id, null, .{ .kind = kind, .actor = actor }, "", now_ms);

        if (title) |t| {
            var stmt = try s.db.prepare("UPDATE issues SET title = ? WHERE id = ?;");
            defer stmt.finalize();
            try stmt.bindText(1, t);
            try stmt.bindBlob(2, &issue_id);
            _ = try stmt.step();
        }
        if (body) |b| {
            var stmt = try s.db.prepare("UPDATE issues SET body = ? WHERE id = ?;");
            defer stmt.finalize();
            try stmt.bindText(1, b);
            try stmt.bindBlob(2, &issue_id);
            _ = try stmt.step();
        }

        // The event is the write that matters; this only moves the concurrency token.
        var touch = try s.db.prepare("UPDATE issues SET last_event_id = ? WHERE id = ?;");
        defer touch.finalize();
        try touch.bindBlob(1, &event_id);
        try touch.bindBlob(2, &issue_id);
        _ = try touch.step();

        try s.db.exec("RELEASE edit_issue;");
    }

    /// The issue's current (projected) state, or null when no such issue exists.
    pub fn issueState(s: *Store, issue_id: Id) Error!?model.Issue.State {
        var stmt = try s.db.prepare("SELECT state FROM issues WHERE id = ?;");
        defer stmt.finalize();
        try stmt.bindBlob(1, &issue_id);
        if (!try stmt.step()) return null;
        return model.Issue.State.parse(stmt.columnText(0));
    }

    /// The issue's optimistic-concurrency token: the id of the last event applied to it,
    /// or null when the issue is missing or has no events yet.
    pub fn lastEventId(s: *Store, issue_id: Id) Error!?Id {
        var stmt = try s.db.prepare("SELECT last_event_id FROM issues WHERE id = ?;");
        defer stmt.finalize();
        try stmt.bindBlob(1, &issue_id);
        if (!try stmt.step()) return null;
        if (stmt.isNull(0)) return null;
        const blob = stmt.columnBlob(0);
        if (blob.len != @sizeOf(Id)) return null;
        var out: Id = undefined;
        @memcpy(&out, blob);
        return out;
    }

    /// How many events the issue's log holds.
    pub fn countEvents(s: *Store, issue_id: Id) Error!i64 {
        var stmt = try s.db.prepare("SELECT count(*) FROM events WHERE issue_id = ?;");
        defer stmt.finalize();
        try stmt.bindBlob(1, &issue_id);
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    // ------------------------------------------------------------ private

    fn appendEventLocked(
        s: *Store,
        event_id: Id,
        issue_id: Id,
        run_id: ?Id,
        event: model.Event,
        payload: []const u8,
        now_ms: i64,
    ) Error!void {
        var stmt = try s.db.prepare(
            "INSERT INTO events(id, issue_id, run_id, actor, kind, payload, created_at) VALUES(?,?,?,?,?,?,?);",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &event_id);
        try stmt.bindBlob(2, &issue_id);
        if (run_id) |r| try stmt.bindBlob(3, &r) else try stmt.bindNull(3);
        try stmt.bindText(4, @tagName(event.actor));
        try stmt.bindText(5, @tagName(event.kind));
        try stmt.bindText(6, payload);
        try stmt.bindInt(7, now_ms);
        _ = try stmt.step();
    }

    /// Private, and called only from the two functions above, both of which reached it by
    /// replaying an event. This is the single `SET state` in the codebase.
    fn setStateRow(s: *Store, issue_id: Id, state: model.Issue.State, event_id: Id) Error!void {
        var stmt = try s.db.prepare("UPDATE issues SET state = ?, last_event_id = ? WHERE id = ?;");
        defer stmt.finalize();
        try stmt.bindText(1, @tagName(state));
        try stmt.bindBlob(2, &event_id);
        try stmt.bindBlob(3, &issue_id);
        _ = try stmt.step();
    }

    // ------------------------------------------------------------ runs

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
    ) Error!void {
        try s.db.exec("SAVEPOINT start_run;");
        errdefer s.db.exec("ROLLBACK TO start_run; RELEASE start_run;") catch {};

        var stmt = try s.db.prepare(
            "INSERT INTO runs(id, issue_id, project_id, branch, token_hash, state, started_at) " ++
                "VALUES(?,?,?,?,?,?,?);",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &run_id);
        try stmt.bindBlob(2, &issue_id);
        try stmt.bindBlob(3, &project_id);
        try stmt.bindText(4, branch);
        try stmt.bindBlob(5, token_hash);
        try stmt.bindText(6, @tagName(model.Run.State.active));
        try stmt.bindInt(7, now_ms);
        _ = try stmt.step();

        const current = (try s.issueState(issue_id)) orelse return error.NoSuchIssue;
        const event = model.Event{ .kind = .state_changed, .actor = .human, .to = .in_progress };
        switch (replay.apply(current, event)) {
            .moved => |next| {
                try s.appendEventLocked(event_id, issue_id, run_id, event, "", now_ms);
                try s.setStateRow(issue_id, next, event_id);
            },
            // Already in progress, say, from a previous run on the same issue.
            .unchanged => {},
            .illegal => return error.IllegalTransition,
        }

        try s.db.exec("RELEASE start_run;");
    }

    /// `ended` means the user quit; `abandoned` means something broke. Keeping them apart
    /// is the point — the dashboard should be able to say which.
    ///
    /// The token hash is cleared at the same time, which is what revocation is: the run
    /// leaves the active set and its token stops resolving.
    pub fn finishRun(s: *Store, run_id: Id, state: model.Run.State, now_ms: i64) Error!void {
        var stmt = try s.db.prepare(
            "UPDATE runs SET state = ?, ended_at = ?, token_hash = NULL " ++
                "WHERE id = ? AND state = 'active';",
        );
        defer stmt.finalize();
        try stmt.bindText(1, @tagName(state));
        try stmt.bindInt(2, now_ms);
        try stmt.bindBlob(3, &run_id);
        _ = try stmt.step();
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
        defer stmt.finalize();

        var rows: std.ArrayList(ActiveRun) = .empty;
        while (try stmt.step()) {
            var run_id: Id = undefined;
            var issue_id: Id = undefined;
            var project_id: Id = undefined;
            if (!copyId(&run_id, stmt.columnBlob(0))) continue;
            if (!copyId(&issue_id, stmt.columnBlob(1))) continue;
            if (!copyId(&project_id, stmt.columnBlob(2))) continue;
            try rows.append(arena, .{
                .run_id = run_id,
                .issue_id = issue_id,
                .project_id = project_id,
                .branch = try arena.dupe(u8, stmt.columnText(3)),
                .token_hash = try arena.dupe(u8, stmt.columnBlob(4)),
            });
        }
        return rows.toOwnedSlice(arena);
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
        defer stmt.finalize();
        try stmt.bindBlob(1, &project_id);
        try stmt.bindInt(2, limit);

        var rows: std.ArrayList(RunRow) = .empty;
        while (try stmt.step()) {
            var run_id: Id = undefined;
            var issue_id: Id = undefined;
            var proj: Id = undefined;
            if (!copyId(&run_id, stmt.columnBlob(0))) continue;
            if (!copyId(&issue_id, stmt.columnBlob(1))) continue;
            if (!copyId(&proj, stmt.columnBlob(2))) continue;
            try rows.append(arena, .{
                .id = run_id,
                .issue_id = issue_id,
                .project_id = proj,
                .branch = try arena.dupe(u8, stmt.columnText(3)),
                .state = std.meta.stringToEnum(model.Run.State, stmt.columnText(4)) orelse .abandoned,
                .started_at = stmt.columnInt(5),
                .ended_at = if (stmt.isNull(6)) null else stmt.columnInt(6),
            });
        }
        return rows.toOwnedSlice(arena);
    }

    /// Anything still marked active whose container is gone is `abandoned`.
    ///
    /// Called both at daemon start and on every poll tick. The poll alone would leave
    /// phantom runs live until it next fired; startup alone would never notice a run that
    /// died while the daemon was up.
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

    // ------------------------------------------------------------ memories

    pub const MemoryRow = struct {
        id: Id,
        state: model.Memory.State,
        body: []const u8,
        /// Newline-separated repo-relative paths.
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
    ) Error!void {
        var stmt = try s.db.prepare(
            "INSERT INTO memories(id, project_id, state, body, anchors, origin_issue_id, created_at) " ++
                "VALUES(?,?,?,?,?,?,?);",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &memory_id);
        try stmt.bindBlob(2, &project_id);
        try stmt.bindText(3, @tagName(model.Memory.State.proposed));
        try stmt.bindText(4, body);
        try stmt.bindText(5, anchors);
        if (origin_issue_id) |o| try stmt.bindBlob(6, &o) else try stmt.bindNull(6);
        try stmt.bindInt(7, now_ms);
        _ = try stmt.step();
    }

    /// The project's memories in creation order; `state` of null means every state.
    /// Rows are copied into `arena`, which owns them.
    pub fn listMemories(
        s: *Store,
        arena: std.mem.Allocator,
        project_id: Id,
        state: ?model.Memory.State,
    ) ![]MemoryRow {
        var stmt = if (state) |_|
            try s.db.prepare(
                "SELECT id, state, body, anchors, origin_issue_id FROM memories " ++
                    "WHERE project_id = ? AND state = ? ORDER BY id;",
            )
        else
            try s.db.prepare(
                "SELECT id, state, body, anchors, origin_issue_id FROM memories " ++
                    "WHERE project_id = ? ORDER BY id;",
            );
        defer stmt.finalize();
        try stmt.bindBlob(1, &project_id);
        if (state) |st| try stmt.bindText(2, @tagName(st));

        var rows: std.ArrayList(MemoryRow) = .empty;
        while (try stmt.step()) {
            var id: Id = undefined;
            if (!copyId(&id, stmt.columnBlob(0))) continue;
            var origin: ?Id = null;
            if (!stmt.isNull(4)) {
                var o: Id = undefined;
                if (copyId(&o, stmt.columnBlob(4))) origin = o;
            }
            try rows.append(arena, .{
                .id = id,
                .state = std.meta.stringToEnum(model.Memory.State, stmt.columnText(1)) orelse .proposed,
                .body = try arena.dupe(u8, stmt.columnText(2)),
                .anchors = try arena.dupe(u8, stmt.columnText(3)),
                .origin_issue_id = origin,
            });
        }
        return rows.toOwnedSlice(arena);
    }

    /// How many memories are active — the number the cap in memory.zig is checked
    /// against.
    pub fn countActiveMemories(s: *Store, project_id: Id) Error!i64 {
        var stmt = try s.db.prepare(
            "SELECT count(*) FROM memories WHERE project_id = ? AND state = 'active';",
        );
        defer stmt.finalize();
        try stmt.bindBlob(1, &project_id);
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    /// Moves a memory between states. The hard cap is enforced by the caller, which has
    /// the whole review buffer in view and can tell an accept that frees a slot from one
    /// that does not.
    pub fn setMemoryState(s: *Store, memory_id: Id, state: model.Memory.State, now_ms: i64) Error!void {
        var stmt = try s.db.prepare(
            "UPDATE memories SET state = ?, reviewed_at = ? WHERE id = ?;",
        );
        defer stmt.finalize();
        try stmt.bindText(1, @tagName(state));
        try stmt.bindInt(2, now_ms);
        try stmt.bindBlob(3, &memory_id);
        _ = try stmt.step();
    }

    /// Overwrites a memory's body and anchors with what the reviewer left in the buffer.
    /// Memories are the one editable record — tightening the wording at review time is
    /// half the point of reviewing.
    pub fn editMemory(s: *Store, memory_id: Id, body: []const u8, anchors: []const u8, now_ms: i64) Error!void {
        var stmt = try s.db.prepare(
            "UPDATE memories SET body = ?, anchors = ?, reviewed_at = ? WHERE id = ?;",
        );
        defer stmt.finalize();
        try stmt.bindText(1, body);
        try stmt.bindText(2, anchors);
        try stmt.bindInt(3, now_ms);
        try stmt.bindBlob(4, &memory_id);
        _ = try stmt.step();
    }

    fn copyId(out: *Id, blob: []const u8) bool {
        if (blob.len != @sizeOf(Id)) return false;
        @memcpy(out, blob);
        return true;
    }
};

/// Derivable in both directions without a lookup table, so the world-model poll can map
/// `podman ps` output straight onto runs.
pub fn containerName(arena: std.mem.Allocator, run_id: Id) ![]const u8 {
    return std.fmt.allocPrint(arena, "capsule-{s}", .{ids.toHex(run_id)[0..12]});
}

// ---------------------------------------------------------------- tests

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
    try testing.expectError(error.Constraint, s.addProject(seeded(2), "/p", "default", 1001));
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
    // The trust posture rests on state being derived from events, never patched. A second
    // hit here means someone added a shortcut that replay cannot account for.
    // Specifically `issues.state`, which is a cached replay of the event log. `runs.state`
    // is an ordinary column and is written directly on purpose.
    //
    // Matches the SQL, not the prose about it: the comments above name the pattern
    // deliberately. The needle is assembled at comptime so this line is not itself a hit.
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

    // Agent-filed issues land in `proposed` and are never mixed into the dispatchable set.
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

    // A second terminal, still holding the token from before the first edit.
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
    // Gone from the active set, which is exactly what revocation means here.
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
    // The unclean-exit path can fire after the clean one; the first answer wins.
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
    // This is the daemon-startup case: nothing survived a reboot.
    try testing.expectEqual(@as(usize, 1), try s.reconcileRuns(a.allocator(), &.{}, 1003));
    try testing.expectEqual(@as(usize, 0), (try s.activeRuns(a.allocator())).len);
}

test "the container name is derivable from the run id in both directions" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const name = try containerName(a.allocator(), seeded(0xab));
    try testing.expect(std.mem.startsWith(u8, name, "capsule-"));
    // Twelve hex characters: enough that the poll can map podman output onto runs with
    // no lookup table, short enough to read in `podman ps`.
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

    // Regression: force used to issue only the project DELETE, which the children's
    // foreign keys rejected — the flag could never do what its message promised.
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

    // The triage/review shape: several savepoint-based writes inside one BEGIN. The
    // rollback must take all of them, or "applied together" is a fiction.
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
