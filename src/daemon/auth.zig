//! Turning an `Authorization` header into the run it was minted for.
//!
//! `token.zig` is generic over the id type and knows nothing about the store, so the
//! binding set has to be built somewhere from the rows the store actually returns. Both
//! endpoints an agent authenticates against — `/mcp` and `/status` — build it here, so a
//! token one accepts is a token the other accepts.

const std = @import("std");

const ids = @import("../id.zig");
const store_mod = @import("../store.zig");
const token_mod = @import("../token.zig");

const Daemon = @import("../daemon.zig").Daemon;

/// The bindings `token.resolve` matches a presented token against, one per live run.
///
/// A row whose `token_hash` is not exactly a `token.Hash` cannot match any token, so it
/// is dropped — which is why the result is `bindings[0..n]` and not the whole allocation.
pub fn bindingsFor(
    arena: std.mem.Allocator,
    active: []const store_mod.Store.ActiveRun,
) ![]const token_mod.Binding(ids.Id) {
    var bindings = try arena.alloc(token_mod.Binding(ids.Id), active.len);
    var n: usize = 0;
    for (active) |run| {
        if (run.token_hash.len != @sizeOf(token_mod.Hash)) continue;
        var digest: token_mod.Hash = undefined;
        @memcpy(&digest, run.token_hash);
        bindings[n] = .{
            .run_id = run.run_id,
            .issue_id = run.issue_id,
            .project_id = run.project_id,
            .token_hash = digest,
        };
        n += 1;
    }
    return bindings[0..n];
}

/// The header resolved against every live run. Fails only if the store does; an absent
/// or unrecognised token is a `Resolution`, not an error.
pub fn resolveToken(
    d: *Daemon,
    arena: std.mem.Allocator,
    authorization: ?[]const u8,
) !token_mod.Resolution(ids.Id) {
    const active = try d.store.activeRuns(arena);
    return token_mod.resolve(ids.Id, authorization, try bindingsFor(arena, active));
}

const testing = std.testing;

fn testId(byte: u8) ids.Id {
    return @splat(byte);
}

fn activeRun(byte: u8, token_hash: []const u8) store_mod.Store.ActiveRun {
    return .{
        .run_id = testId(byte),
        .issue_id = testId(byte + 100),
        .project_id = testId(byte + 200),
        .branch = "capsule/x",
        .token_hash = token_hash,
    };
}

test "a run whose stored hash is the wrong size is dropped, not carried through" {
    // Without the guard the `@memcpy` gets mismatched lengths, which is illegal
    // behaviour — a panic in a safe build, on a path any agent can reach.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const good: token_mod.Hash = @splat(0xAA);
    const active = [_]store_mod.Store.ActiveRun{
        activeRun(1, "too short"),
        activeRun(2, &good),
        activeRun(3, ""),
        activeRun(4, &(good ++ [_]u8{0})),
    };

    const bindings = try bindingsFor(arena.allocator(), &active);
    try testing.expectEqual(@as(usize, 1), bindings.len);
    try testing.expectEqual(testId(2), bindings[0].run_id);
    try testing.expectEqual(testId(102), bindings[0].issue_id);
    try testing.expectEqual(testId(202), bindings[0].project_id);
}

test "a binding owns its digest rather than pointing at the row" {
    // This pins the field *type*, not the assignment: `Binding.token_hash` is a `Hash`
    // array, so the copy is automatic. Widening it to `[]const u8` would still compile,
    // and every binding would then read whatever the store's arena reused.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var source: token_mod.Hash = @splat(0x11);
    const active = [_]store_mod.Store.ActiveRun{activeRun(1, &source)};

    const bindings = try bindingsFor(arena.allocator(), &active);
    source = @splat(0x22);

    try testing.expectEqual(@as(token_mod.Hash, @splat(0x11)), bindings[0].token_hash);
}

test "no live runs means nothing to match against" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const bindings = try bindingsFor(arena.allocator(), &.{});
    try testing.expectEqual(@as(usize, 0), bindings.len);
    try testing.expect(token_mod.resolve(ids.Id, "x" ** token_mod.encoded_len, bindings) == .unknown);
}

test "a token minted for one run resolves to that run and no other" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const mine = "m" ** token_mod.encoded_len;
    const theirs = "t" ** token_mod.encoded_len;
    const my_hash = token_mod.hash(mine);
    const their_hash = token_mod.hash(theirs);

    const active = [_]store_mod.Store.ActiveRun{
        activeRun(7, &their_hash),
        activeRun(9, &my_hash),
    };
    const bindings = try bindingsFor(arena.allocator(), &active);

    switch (token_mod.resolve(ids.Id, mine, bindings)) {
        .ok => |binding| try testing.expectEqual(testId(9), binding.run_id),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(token_mod.resolve(ids.Id, null, bindings) == .absent);
    try testing.expect(token_mod.resolve(ids.Id, "nope", bindings) == .unknown);
}
