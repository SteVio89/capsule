//! Memory: the cap, and staleness.

const std = @import("std");
const model = @import("model.zig");

pub const active_cap = model.Memory.active_cap;
pub const token_budget = model.Memory.token_budget;

pub const Verb = enum {
    keep,
    /// proposed → active
    activate,
    /// proposed → inactive
    discard,
    /// active → inactive, which frees a slot
    deactivate,

    /// The verb exactly as spelled in a triage buffer, or null for anything else.
    pub fn parse(text: []const u8) ?Verb {
        return std.meta.stringToEnum(Verb, text);
    }
};

pub const Decision = struct {
    id: []const u8,
    verb: Verb,
};

pub const Refusal = struct {
    /// How many would be active if this were applied.
    would_be: usize,
    activating: usize,
};

pub const Outcome = union(enum) {
    applied,
    /// The cap is enforced, not advisory. Warn-and-allow would make it decorative and the
    /// set becomes a junk drawer; refusing is what forces the argument that the new one
    /// beats an existing one, and that argument *is* the curation.
    refused: Refusal,
};

/// Pure: the current active count and a buffer's verbs in, applied or refused out.
pub fn applyCap(active_now: usize, decisions: []const Decision) Outcome {
    var activating: usize = 0;
    var freeing: usize = 0;
    for (decisions) |decision| switch (decision.verb) {
        .activate => activating += 1,
        .deactivate => freeing += 1,
        .keep, .discard => {},
    };

    const would_be = active_now + activating - @min(freeing, active_now);
    if (would_be > active_cap) return .{ .refused = .{ .would_be = would_be, .activating = activating } };
    return .applied;
}

/// Rough, and labelled as such wherever it is shown. There is no tokeniser here and
/// pulling one in for a soft warning would be absurd.
pub fn estimateTokens(bodies: []const []const u8) usize {
    var bytes: usize = 0;
    for (bodies) |body| bytes += body.len;
    return bytes / 4;
}

/// True when the estimate crosses the soft budget. A warning trigger, not a gate —
/// unlike the count cap, nothing is refused over it.
pub fn overBudget(bodies: []const []const u8) bool {
    return estimateTokens(bodies) > token_budget;
}

/// A memory is suspect when a path it is anchored to has been deleted or renamed.
pub fn isSuspect(anchors: []const u8, gone: []const []const u8) bool {
    var lines = std.mem.splitScalar(u8, anchors, '\n');
    while (lines.next()) |raw| {
        const anchor = std.mem.trim(u8, raw, " \t\r");
        if (anchor.len == 0) continue;
        for (gone) |path| {
            if (std.mem.eql(u8, anchor, path)) return true;
        }
    }
    return false;
}

/// Anchors detect staleness and nothing else. They are deliberately *not* used to choose
/// which memories to inject: at `get_issue` time the agent does not yet know which files
/// it will touch, so filtering on them would be guessing.
pub fn anchorCount(anchors: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, anchors, '\n');
    while (lines.next()) |raw| {
        if (std.mem.trim(u8, raw, " \t\r").len > 0) n += 1;
    }
    return n;
}

const testing = std.testing;

fn plan(comptime verbs: []const Verb) [verbs.len]Decision {
    var out: [verbs.len]Decision = undefined;
    for (verbs, 0..) |verb, i| out[i] = .{ .id = "x", .verb = verb };
    return out;
}

test "under the cap, activations apply" {
    const d = plan(&.{ .activate, .activate });
    try testing.expectEqual(Outcome.applied, applyCap(10, &d));
}

test "accepting at exactly the cap is refused" {
    const d = plan(&.{.activate});
    switch (applyCap(active_cap, &d)) {
        .refused => |r| try testing.expectEqual(active_cap + 1, r.would_be),
        .applied => return error.ShouldHaveRefused,
    }
}

test "accepting at the cap is allowed when the same buffer frees a slot" {
    const d = plan(&.{ .activate, .deactivate });
    try testing.expectEqual(Outcome.applied, applyCap(active_cap, &d));
}

test "two activations need two deactivations" {
    try testing.expectEqual(
        Outcome.applied,
        applyCap(active_cap, &plan(&.{ .activate, .activate, .deactivate, .deactivate })),
    );
    switch (applyCap(active_cap, &plan(&.{ .activate, .activate, .deactivate }))) {
        .refused => {},
        .applied => return error.ShouldHaveRefused,
    }
}

test "discarding does not free a slot, because it was never taking one" {
    switch (applyCap(active_cap, &plan(&.{ .activate, .discard }))) {
        .refused => {},
        .applied => return error.ShouldHaveRefused,
    }
}

test "deactivating alone is always fine" {
    try testing.expectEqual(Outcome.applied, applyCap(active_cap, &plan(&.{.deactivate})));
    try testing.expectEqual(Outcome.applied, applyCap(0, &plan(&.{.deactivate})));
}

test "an empty buffer changes nothing, even at the cap" {
    try testing.expectEqual(Outcome.applied, applyCap(active_cap, &.{}));
}

test "the token budget is a warning about verbosity, not about count" {
    var short: [active_cap][]const u8 = undefined;
    for (&short) |*body| body.* = "X not Y, because Z. It bit us once already.";
    try testing.expect(!overBudget(&short));

    var long: [active_cap][]const u8 = undefined;
    for (&long) |*body| body.* = "x" ** 400;
    try testing.expect(overBudget(&long));
}

test "a memory is suspect only when an anchor is gone" {
    try testing.expect(isSuspect("src/limit.zig\ntest/run.sh", &.{"src/limit.zig"}));
    try testing.expect(!isSuspect("src/limit.zig", &.{"src/other.zig"}));
    try testing.expect(!isSuspect("src/limit.zig", &.{}));
    try testing.expect(!isSuspect("", &.{"anything"}));
}

test "anchors are counted, blank lines ignored" {
    try testing.expectEqual(@as(usize, 0), anchorCount(""));
    try testing.expectEqual(@as(usize, 0), anchorCount("\n  \n"));
    try testing.expectEqual(@as(usize, 2), anchorCount("a.zig\nb.zig\n"));
}

test "verbs parse, and a triage verb is not one of them" {
    try testing.expectEqual(Verb.activate, Verb.parse("activate").?);
    try testing.expectEqual(Verb.deactivate, Verb.parse("deactivate").?);
    try testing.expectEqual(@as(?Verb, null), Verb.parse("accept"));
    try testing.expectEqual(@as(?Verb, null), Verb.parse("reject"));
}
