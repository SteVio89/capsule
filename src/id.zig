//! UUIDv7 identifiers and git-style unique-prefix resolution.

const std = @import("std");

pub const Id = [16]u8;

/// How much of an ID the dashboard and `issue list` show, taken from the **end**: a
/// UUIDv7 opens with a timestamp, so the leading characters barely differ between issues.
pub const short_len = 8;

pub const hex_len = 32;

/// Takes the clock reading and the random bytes rather than sourcing either, so tests are
/// neither timing-dependent nor flaky.
pub fn generate(unix_ms: i64, entropy: [16]u8) Id {
    var id: Id = entropy;

    const ms: u48 = @truncate(@as(u64, @bitCast(unix_ms)));
    std.mem.writeInt(u48, id[0..6], ms, .big);

    id[6] = (id[6] & 0x0f) | 0x70; // version 7
    id[8] = (id[8] & 0x3f) | 0x80; // RFC 4122 variant
    return id;
}

/// Randomness moved behind the Io interface in 0.16; there is no `std.crypto.random` any
/// more.
pub fn generateNow(io: std.Io) Id {
    var entropy: [16]u8 = undefined;
    io.random(&entropy);
    return generate(std.Io.Timestamp.now(io, .real).toMilliseconds(), entropy);
}

/// Milliseconds since the epoch, recovered from the leading 48 bits.
pub fn timestampMs(id: Id) i64 {
    return @intCast(std.mem.readInt(u48, id[0..6], .big));
}

/// The canonical rendering: 32 lowercase hex characters, no dashes. Returned by value.
pub fn toHex(id: Id) [hex_len]u8 {
    var out: [hex_len]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{&id}) catch unreachable;
    return out;
}

/// The display prefix: the last `short_len` hex characters, which are pure entropy
/// rather than the shared timestamp (see `short_len`). Returned by value.
pub fn short(id: Id) [short_len]u8 {
    const hex = toHex(id);
    return hex[hex.len - short_len ..].*;
}

pub const ParseError = error{ BadLength, BadDigit };

/// Parses the exact 32-character hex form back into an `Id`. Case-insensitive;
/// anything else is `BadLength` or `BadDigit`.
pub fn parseHex(text: []const u8) ParseError!Id {
    if (text.len != hex_len) return error.BadLength;
    var id: Id = undefined;
    for (&id, 0..) |*byte, i| {
        const hi = try nibble(text[i * 2]);
        const lo = try nibble(text[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
    return id;
}

fn nibble(c: u8) ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.BadDigit,
    };
}

/// Git's short-SHA behaviour: a prefix resolves when exactly one ID starts with it.
pub const Resolution = union(enum) {
    resolved: usize,
    ambiguous,
    missing,
    /// Empty, over-long, or containing something that is not a hex digit. Distinct from
    /// `missing`: a typo'd prefix and a prefix for an issue that does not exist deserve
    /// different messages.
    malformed,
};

/// Accepts what a person would actually type: a leading piece of the **short id** (what
/// `issue list` prints), or a leading piece of the full hex (what the API returns).
pub fn resolvePrefix(prefix: []const u8, ids: []const Id) Resolution {
    if (prefix.len == 0 or prefix.len > hex_len) return .malformed;
    for (prefix) |c| _ = nibble(c) catch return .malformed;

    var found: ?usize = null;
    for (ids, 0..) |id, i| {
        if (!matches(id, prefix)) continue;
        if (found != null) return .ambiguous;
        found = i;
    }
    return if (found) |i| .{ .resolved = i } else .missing;
}

/// True when `prefix` leads either the short id or the full hex — the two forms a
/// user can see. Assumes the prefix is already validated hex; case-insensitive.
pub fn matches(id: Id, prefix: []const u8) bool {
    if (prefix.len <= short_len and std.ascii.eqlIgnoreCase(short(id)[0..prefix.len], prefix)) {
        return true;
    }
    return hasPrefix(id, prefix);
}

/// True when `prefix` leads the full 32-character hex form only (not the short id).
pub fn hasPrefix(id: Id, prefix: []const u8) bool {
    const hex = toHex(id);
    if (prefix.len > hex.len) return false;
    return std.ascii.eqlIgnoreCase(hex[0..prefix.len], prefix);
}

const testing = std.testing;

fn fixed(hex: *const [hex_len]u8) Id {
    return parseHex(hex) catch unreachable;
}

test "generate stamps the version, the variant, and the clock" {
    const entropy = [_]u8{0} ** 16;
    const ms: i64 = 1_735_689_600_123;
    const id = generate(ms, entropy);

    try testing.expectEqual(@as(u8, 0x70), id[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), id[8] & 0xc0);
    try testing.expectEqual(ms, timestampMs(id));
}

test "generated ids sort by creation time as byte strings" {
    const entropy = [_]u8{1} ** 16;
    const early = generate(1_000_000_000_000, entropy);
    const late = generate(1_000_000_000_001, entropy);
    try testing.expect(std.mem.lessThan(u8, &early, &late));
}

test "hex round-trips" {
    const entropy = [_]u8{2} ** 16;
    const id = generate(1_735_689_600_000, entropy);
    try testing.expectEqual(id, try parseHex(&toHex(id)));
}

test "parseHex rejects bad input" {
    try testing.expectError(error.BadLength, parseHex("018f2a1c"));
    try testing.expectError(error.BadLength, parseHex("0" ** 33));
    try testing.expectError(error.BadDigit, parseHex("g" ** 32));
}

test "resolvePrefix: resolved, ambiguous, missing, malformed" {
    const ids = [_]Id{
        fixed("018f2a1c00000000000000000000aaaa"),
        fixed("018f2a3d00000000000000000000bbbb"),
        fixed("018f2a3e00000000000000000000cccc"),
    };

    try testing.expectEqual(Resolution{ .resolved = 0 }, resolvePrefix("018f2a1c", &ids));
    try testing.expectEqual(Resolution{ .resolved = 0 }, resolvePrefix("018f2a1", &ids));
    try testing.expectEqual(Resolution.ambiguous, resolvePrefix("018f2a3", &ids));
    try testing.expectEqual(Resolution.ambiguous, resolvePrefix("018f2a", &ids));
    try testing.expectEqual(Resolution.missing, resolvePrefix("beef", &ids));
    try testing.expectEqual(Resolution.malformed, resolvePrefix("", &ids));
    try testing.expectEqual(Resolution.malformed, resolvePrefix("zz", &ids));
    try testing.expectEqual(Resolution.malformed, resolvePrefix("0" ** 33, &ids));
}

test "resolvePrefix: a full-length id resolves to itself" {
    const ids = [_]Id{fixed("018f2a1c00000000000000000000aaaa")};
    try testing.expectEqual(
        Resolution{ .resolved = 0 },
        resolvePrefix("018f2a1c00000000000000000000aaaa", &ids),
    );
}

test "resolvePrefix: empty id set is missing, not ambiguous" {
    try testing.expectEqual(Resolution.missing, resolvePrefix("018f", &.{}));
}

test "prefix matching is case-insensitive" {
    const ids = [_]Id{fixed("018f2a1c00000000000000000000aaaa")};
    try testing.expectEqual(Resolution{ .resolved = 0 }, resolvePrefix("018F2A1C", &ids));
}

test "short is the display prefix" {
    const id = fixed("018f2a1c00000000000000000000aaaa");
    try testing.expectEqualStrings("0000aaaa", &short(id));
}

test "short ids come from the entropy, not the clock" {
    var entropy_a = [_]u8{0} ** 16;
    var entropy_b = [_]u8{0} ** 16;
    entropy_a[15] = 0xaa;
    entropy_b[15] = 0xbb;

    const ms: i64 = 1_785_000_000_000;
    const a = generate(ms, entropy_a);
    const b = generate(ms, entropy_b);

    try testing.expect(!std.mem.eql(u8, &short(a), &short(b)));
}

test "a short id resolves, and so does a leading piece of the full hex" {
    const ids = [_]Id{
        fixed("018f2a1c00000000000000000000aaaa"),
        fixed("018f2a1c00000000000000000000bbbb"),
    };
    try testing.expectEqual(Resolution.ambiguous, resolvePrefix("018f2a1c", &ids));

    try testing.expectEqual(Resolution{ .resolved = 0 }, resolvePrefix("0000aaaa", &ids));
    try testing.expectEqual(Resolution{ .resolved = 1 }, resolvePrefix("0000bbbb", &ids));
    try testing.expectEqual(
        Resolution{ .resolved = 0 },
        resolvePrefix("018f2a1c00000000000000000000aaaa", &ids),
    );
}
