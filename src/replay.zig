//! Event replay: `(state, event) -> outcome`, and nothing else.

const std = @import("std");
const model = @import("model.zig");

const State = model.Issue.State;
const Event = model.Event;

pub const Illegal = enum {
    /// An event other than `created` / `filed_by_agent` arrived for an issue that does
    /// not exist yet.
    no_such_issue,
    /// `created` or `filed_by_agent` arrived for an issue that already exists.
    already_exists,
    /// `done` is terminal; nothing moves an issue out of it.
    terminal,
    /// The transition is not reachable from this state — reopening something that was
    /// never archived, triaging something already triaged.
    unreachable_from,
    /// `state_changed` without a target state.
    missing_target,
    /// Agents may only report `in_progress`, `blocked`, or `ready_for_review`. `done` in
    /// particular is reachable only by merging.
    agent_may_not,
};

pub const Outcome = union(enum) {
    moved: State,
    /// Legal, but carries no state change: comments, edits, renames.
    unchanged,
    illegal: Illegal,
};

/// `current` is null for an issue that does not exist yet, which is how a replay starts.
pub fn apply(current: ?State, event: Event) Outcome {
    const state = current orelse return switch (event.kind) {
        .created => .{ .moved = .open },
        .filed_by_agent => .{ .moved = .proposed },
        else => .{ .illegal = .no_such_issue },
    };

    switch (event.kind) {
        .created, .filed_by_agent => return .{ .illegal = .already_exists },

        .commented => return .unchanged,
        else => {},
    }

    if (state == .done) return .{ .illegal = .terminal };

    switch (event.kind) {
        .created, .filed_by_agent, .commented => unreachable,

        .edited, .renamed => return .unchanged,

        .state_changed => {
            const to = event.to orelse return .{ .illegal = .missing_target };
            if (event.actor == .agent) switch (to) {
                .in_progress, .blocked, .ready_for_review => {},
                else => return .{ .illegal = .agent_may_not },
            };
            switch (state) {
                .proposed, .archived => return .{ .illegal = .unreachable_from },
                else => {},
            }
            switch (to) {
                .open, .in_progress, .blocked, .ready_for_review => return .{ .moved = to },
                .done, .archived, .proposed => return .{ .illegal = .unreachable_from },
            }
        },

        .triaged => return switch (state) {
            .proposed => .{ .moved = .open },
            else => .{ .illegal = .unreachable_from },
        },

        .archived => return switch (state) {
            .archived, .done => .{ .illegal = .unreachable_from },
            else => .{ .moved = .archived },
        },

        .reopened => return switch (state) {
            .archived => .{ .moved = .open },
            else => .{ .illegal = .unreachable_from },
        },

        .merged => return switch (state) {
            .open, .in_progress, .blocked, .ready_for_review => .{ .moved = .done },
            .proposed, .archived, .done => .{ .illegal = .unreachable_from },
        },
    }
}

/// Fold a whole event log. Illegal events are the store's problem to reject at append
/// time; if one is somehow present, replaying it must not silently rewrite history, so
/// it is skipped and the state it could not reach is simply never reached.
pub fn fold(events: []const Event) ?State {
    var state: ?State = null;
    for (events) |event| {
        switch (apply(state, event)) {
            .moved => |next| state = next,
            .unchanged, .illegal => {},
        }
    }
    return state;
}

const testing = std.testing;

fn human(kind: Event.Kind) Event {
    return .{ .kind = kind, .actor = .human };
}
fn agentSets(to: State) Event {
    return .{ .kind = .state_changed, .actor = .agent, .to = to };
}
fn humanSets(to: State) Event {
    return .{ .kind = .state_changed, .actor = .human, .to = to };
}

test "an issue begins as open, or as proposed when an agent filed it" {
    try testing.expectEqual(Outcome{ .moved = .open }, apply(null, human(.created)));
    try testing.expectEqual(
        Outcome{ .moved = .proposed },
        apply(null, .{ .kind = .filed_by_agent, .actor = .agent }),
    );
}

test "nothing but creation applies to an issue that does not exist" {
    for ([_]Event.Kind{ .edited, .renamed, .state_changed, .commented, .triaged, .archived, .reopened, .merged }) |kind| {
        try testing.expectEqual(Outcome{ .illegal = .no_such_issue }, apply(null, human(kind)));
    }
}

test "creating something that already exists is rejected, not idempotent" {
    try testing.expectEqual(Outcome{ .illegal = .already_exists }, apply(.open, human(.created)));
    try testing.expectEqual(
        Outcome{ .illegal = .already_exists },
        apply(.open, .{ .kind = .filed_by_agent, .actor = .agent }),
    );
}

test "the agent's reachable states, and only those" {
    for ([_]State{ .in_progress, .blocked, .ready_for_review }) |to| {
        try testing.expectEqual(Outcome{ .moved = to }, apply(.open, agentSets(to)));
    }
    for ([_]State{ .done, .archived, .proposed, .open }) |to| {
        try testing.expectEqual(Outcome{ .illegal = .agent_may_not }, apply(.in_progress, agentSets(to)));
    }
}

test "merge is the only path to done" {
    try testing.expectEqual(Outcome{ .moved = .done }, apply(.ready_for_review, human(.merged)));
    try testing.expectEqual(Outcome{ .moved = .done }, apply(.in_progress, human(.merged)));
    try testing.expectEqual(Outcome{ .illegal = .unreachable_from }, apply(.open, humanSets(.done)));
    try testing.expectEqual(Outcome{ .illegal = .agent_may_not }, apply(.open, agentSets(.done)));
}

test "done is terminal for everything that would move it" {
    for ([_]Event.Kind{ .state_changed, .archived, .reopened, .merged, .edited, .renamed }) |kind| {
        var event = human(kind);
        if (kind == .state_changed) event.to = .open;
        try testing.expectEqual(Outcome{ .illegal = .terminal }, apply(.done, event));
    }
}

test "a comment is always legal, even after merge" {
    try testing.expectEqual(Outcome.unchanged, apply(.done, human(.commented)));
    try testing.expectEqual(Outcome.unchanged, apply(.archived, human(.commented)));
    try testing.expectEqual(Outcome.unchanged, apply(.open, human(.commented)));
}

test "triage accepts only from proposed" {
    try testing.expectEqual(Outcome{ .moved = .open }, apply(.proposed, human(.triaged)));
    for ([_]State{ .open, .in_progress, .blocked, .ready_for_review, .archived }) |from| {
        try testing.expectEqual(Outcome{ .illegal = .unreachable_from }, apply(from, human(.triaged)));
    }
}

test "archive is reachable from everything live, and reopen only from archived" {
    for ([_]State{ .proposed, .open, .in_progress, .blocked, .ready_for_review }) |from| {
        try testing.expectEqual(Outcome{ .moved = .archived }, apply(from, human(.archived)));
    }
    try testing.expectEqual(Outcome{ .illegal = .unreachable_from }, apply(.archived, human(.archived)));
    try testing.expectEqual(Outcome{ .moved = .open }, apply(.archived, human(.reopened)));
    try testing.expectEqual(Outcome{ .illegal = .unreachable_from }, apply(.open, human(.reopened)));
}

test "a proposed issue has no working state to report from" {
    try testing.expectEqual(Outcome{ .illegal = .unreachable_from }, apply(.proposed, agentSets(.in_progress)));
    try testing.expectEqual(Outcome{ .illegal = .unreachable_from }, apply(.proposed, human(.merged)));
}

test "state_changed without a target is rejected" {
    try testing.expectEqual(
        Outcome{ .illegal = .missing_target },
        apply(.open, .{ .kind = .state_changed, .actor = .human }),
    );
}

test "fold walks a realistic life" {
    const events = [_]Event{
        human(.created),
        agentSets(.in_progress),
        human(.commented),
        agentSets(.blocked),
        agentSets(.ready_for_review),
        human(.merged),
    };
    try testing.expectEqual(State.done, fold(&events).?);
}

test "fold: an archived issue reopens onto open" {
    const events = [_]Event{ human(.created), human(.archived), human(.reopened) };
    try testing.expectEqual(State.open, fold(&events).?);
}

test "fold: an illegal event cannot rewrite the state around it" {
    const events = [_]Event{ human(.created), human(.merged), agentSets(.in_progress) };
    try testing.expectEqual(State.done, fold(&events).?);
}

test "fold of nothing is nothing" {
    try testing.expectEqual(@as(?State, null), fold(&.{}));
}
