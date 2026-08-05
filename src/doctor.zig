//! Does the event log still agree with the projection built from it?
//!
//! `issues.state` is a cache: written by the event applier, never invalidated, and read
//! by everything. Nothing has ever checked it against the log it came from. This replays
//! the log and compares — the one thing that can tell a stale cache from a correct one.
//!
//! Pure over rows on purpose, so the whole of it is testable without a store.

const std = @import("std");

const ids = @import("id.zig");
const model = @import("model.zig");
const replay = @import("replay.zig");
const store_mod = @import("store.zig");

pub const Verdict = enum {
    /// The replay reached exactly the state the issue records.
    ok,
    /// The replay reached a different state. The log is the source of truth, so this
    /// means the cached state is wrong.
    drift,
    /// The log holds a `state_changed` with no recorded target, so the replay cannot
    /// reach a verdict. Written before the `to_state` column existed.
    unverifiable,
    /// An issue with no events at all. `createIssue` writes one in the same transaction
    /// as the issue, so this cannot happen through the normal path.
    no_events,
    /// `last_event_id` names an event that is not in this issue's log — the
    /// optimistic-concurrency token points at nothing, so editor writeback cannot work.
    dangling_last_event,
    /// A column this build cannot decode, in the issue's own state or in one of its
    /// events. The store hands back a usable fallback so the rest of capsule keeps
    /// working; a replay must not fold it, because both sides of the comparison would
    /// then be things nobody stored.
    unreadable,
};

pub const Report = struct {
    verdict: Verdict,
    /// What the log replays to, when the replay reached a verdict at all.
    replayed: ?model.Issue.State = null,
    /// Which column could not be decoded, when the verdict is `unreadable`.
    unreadable: ?model.Unreadable = null,
};

/// Replays `events` and compares the result against the issue's recorded state.
///
/// `events` must be this issue's whole log, oldest first — which is what
/// `store.listEvents` returns. Allocates the replay input from `arena`.
pub fn check(
    arena: std.mem.Allocator,
    issue: store_mod.Store.IssueRow,
    events: []const store_mod.Store.EventRow,
) !Report {
    // Before anything else: if the issue's own state column did not decode, `issue.state`
    // is the `.open` fallback, and comparing a replay against it would report drift on
    // every corrupt row while naming the wrong cause.
    if (issue.unreadable) |u| return .{ .verdict = .unreadable, .unreadable = u };

    if (events.len == 0) return .{ .verdict = .no_events };

    for (events) |event| {
        if (event.unreadable) |u| return .{ .verdict = .unreadable, .unreadable = u };
    }

    if (issue.last_event_id) |last| {
        const found = for (events) |event| {
            if (std.mem.eql(u8, &event.id, &last)) break true;
        } else false;
        if (!found) return .{ .verdict = .dangling_last_event };
    }

    for (events) |event| {
        if (event.kind == .state_changed and event.to == null) {
            return .{ .verdict = .unverifiable };
        }
    }

    const log = try arena.alloc(model.Event, events.len);
    for (events, log) |event, *out| {
        out.* = .{ .kind = event.kind, .actor = event.actor, .to = event.to };
    }
    const replayed = replay.fold(log);

    return .{
        .verdict = if (replayed == issue.state) .ok else .drift,
        .replayed = replayed,
    };
}

const testing = std.testing;

fn testId(byte: u8) ids.Id {
    return @splat(byte);
}

fn issueRow(state: model.Issue.State, last_event_id: ?ids.Id) store_mod.Store.IssueRow {
    return .{
        .id = testId(200),
        .title = "t",
        .body = "b",
        .state = state,
        .last_event_id = last_event_id,
        .created_at = 1000,
    };
}

fn logged(byte: u8, kind: model.Event.Kind, actor: model.Event.Actor, to: ?model.Issue.State) store_mod.Store.EventRow {
    return .{
        .id = testId(byte),
        .kind = kind,
        .actor = actor,
        .payload = "",
        .created_at = 1000 + @as(i64, byte),
        .run_id = null,
        .to = to,
    };
}

test "a log that replays to the recorded state is clean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const events = [_]store_mod.Store.EventRow{
        logged(1, .created, .human, null),
        logged(2, .state_changed, .agent, .in_progress),
        logged(3, .state_changed, .agent, .ready_for_review),
    };
    const report = try check(arena.allocator(), issueRow(.ready_for_review, testId(3)), &events);
    try testing.expectEqual(Verdict.ok, report.verdict);
    try testing.expectEqual(model.Issue.State.ready_for_review, report.replayed.?);
}

test "a cached state the log cannot justify is drift, and the log wins" {
    // The whole point of the check: `issues.state` says one thing, the append-only log
    // says another, and it is the cache that is wrong.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const events = [_]store_mod.Store.EventRow{
        logged(1, .created, .human, null),
        logged(2, .state_changed, .agent, .blocked),
    };
    const report = try check(arena.allocator(), issueRow(.done, testId(2)), &events);
    try testing.expectEqual(Verdict.drift, report.verdict);
    try testing.expectEqual(model.Issue.State.blocked, report.replayed.?);
}

test "a state_changed with no recorded target cannot be judged either way" {
    // Rows written before `to_state` existed. Reporting these as drift would flag every
    // pre-existing issue, which is worse than saying nothing.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const events = [_]store_mod.Store.EventRow{
        logged(1, .created, .human, null),
        logged(2, .state_changed, .human, null),
    };
    const report = try check(arena.allocator(), issueRow(.in_progress, testId(2)), &events);
    try testing.expectEqual(Verdict.unverifiable, report.verdict);
    try testing.expectEqual(@as(?model.Issue.State, null), report.replayed);
}

test "only state_changed needs a target — other kinds carry none by design" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const events = [_]store_mod.Store.EventRow{
        logged(1, .created, .human, null),
        logged(2, .commented, .human, null),
        logged(3, .merged, .human, null),
    };
    const report = try check(arena.allocator(), issueRow(.done, testId(3)), &events);
    try testing.expectEqual(Verdict.ok, report.verdict);
}

test "an issue with no log at all is reported rather than replayed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const report = try check(arena.allocator(), issueRow(.open, null), &.{});
    try testing.expectEqual(Verdict.no_events, report.verdict);
}

test "a last_event_id naming no event in the log breaks editor writeback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const events = [_]store_mod.Store.EventRow{logged(1, .created, .human, null)};
    const report = try check(arena.allocator(), issueRow(.open, testId(9)), &events);
    try testing.expectEqual(Verdict.dangling_last_event, report.verdict);

    const good = try check(arena.allocator(), issueRow(.open, testId(1)), &events);
    try testing.expectEqual(Verdict.ok, good.verdict);
}

test "an issue that never had a last_event_id is still replayed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const events = [_]store_mod.Store.EventRow{logged(1, .created, .human, null)};
    const report = try check(arena.allocator(), issueRow(.open, null), &events);
    try testing.expectEqual(Verdict.ok, report.verdict);
}

test "a state column this build cannot decode is not reported as drift" {
    // The store hands back `.open` so the rest of capsule keeps working. Comparing a
    // replay against that fallback would report drift on every corrupt row and name
    // entirely the wrong cause.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var issue = issueRow(.open, testId(1));
    issue.unreadable = .{ .column = "state", .value = "frobnicated" };

    const events = [_]store_mod.Store.EventRow{
        logged(1, .created, .human, null),
        logged(2, .merged, .human, null),
    };
    const report = try check(arena.allocator(), issue, &events);
    try testing.expectEqual(Verdict.unreadable, report.verdict);
    try testing.expectEqualStrings("state", report.unreadable.?.column);
    try testing.expectEqualStrings("frobnicated", report.unreadable.?.value);
}

test "an event kind this build cannot decode stops the replay rather than skewing it" {
    // `listEvents` falls back to `.commented`, which `replay.apply` treats as unchanged —
    // so folding it would silently drop a transition and answer with confidence.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var odd = logged(2, .commented, .human, null);
    odd.unreadable = .{ .column = "kind", .value = "deferred" };

    const events = [_]store_mod.Store.EventRow{ logged(1, .created, .human, null), odd };
    const report = try check(arena.allocator(), issueRow(.open, testId(1)), &events);
    try testing.expectEqual(Verdict.unreadable, report.verdict);
    try testing.expectEqualStrings("kind", report.unreadable.?.column);
    try testing.expectEqual(@as(?model.Issue.State, null), report.replayed);
}
