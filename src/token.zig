//! The per-run token: minted at `run start`, injected into the container, revoked when
//! the run ends.

const std = @import("std");

/// 32 bytes of entropy. Base64url so it survives an env var, a JSON string, and an HTTP
/// header without escaping.
pub const raw_len = 32;
pub const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(raw_len);

pub const Hash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// Mints a fresh token: 32 random bytes, base64url-encoded. Returned by value; the
/// caller is responsible for getting it into the container and never persisting it.
pub fn mint(io: std.Io) [encoded_len]u8 {
    var raw: [raw_len]u8 = undefined;
    io.random(&raw);
    var out: [encoded_len]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&out, &raw);
    return out;
}

/// SHA-256 of the encoded token — the only form that is ever stored. Returned by value.
pub fn hash(token: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &out, .{});
    return out;
}

/// One active run, as far as token resolution is concerned. Returns a struct type
/// generic over the caller's id type so this module needs no dependency on `id.zig`.
pub fn Binding(comptime Id: type) type {
    return struct {
        run_id: Id,
        issue_id: Id,
        project_id: Id,
        token_hash: Hash,
    };
}

/// The outcome of `resolve`, generic over the caller's id type so this module needs no
/// dependency on `id.zig`. `absent` and `unknown` are distinct on purpose: a missing
/// header and an unrecognised token deserve different messages.
pub fn Resolution(comptime Id: type) type {
    return union(enum) {
        ok: Binding(Id),
        /// No `Authorization` header at all.
        absent,
        /// Present but not a token we minted, or belonging to a run that has ended.
        unknown,
    };
}

/// Pure: a header value and the set of live runs in, a binding out.
pub fn resolve(
    comptime Id: type,
    header: ?[]const u8,
    active: []const Binding(Id),
) Resolution(Id) {
    const presented = header orelse return .absent;
    if (presented.len == 0) return .absent;
    if (presented.len != encoded_len) return .unknown;

    const digest = hash(presented);
    for (active) |binding| {
        if (std.crypto.timing_safe.eql(Hash, digest, binding.token_hash)) return .{ .ok = binding };
    }
    return .unknown;
}

const testing = std.testing;
const TestId = [16]u8;

fn id(n: u8) TestId {
    var out: TestId = undefined;
    @memset(&out, n);
    return out;
}

fn bound(n: u8, secret: []const u8) Binding(TestId) {
    return .{
        .run_id = id(n),
        .issue_id = id(n + 1),
        .project_id = id(n + 2),
        .token_hash = hash(secret),
    };
}

test "a token resolves to exactly its own run" {
    const a = "a" ** encoded_len;
    const b = "b" ** encoded_len;
    const active = [_]Binding(TestId){ bound(1, a), bound(10, b) };

    const got = resolve(TestId, a, &active);
    try testing.expectEqual(id(1), got.ok.run_id);
    try testing.expectEqual(id(2), got.ok.issue_id);

    const other = resolve(TestId, b, &active);
    try testing.expectEqual(id(10), other.ok.run_id);
}

test "no header is absent, not unknown" {
    try testing.expectEqual(
        Resolution(TestId).absent,
        resolve(TestId, null, &.{}),
    );
    try testing.expectEqual(
        Resolution(TestId).absent,
        resolve(TestId, "", &.{}),
    );
}

test "an unrecognised token is refused" {
    const active = [_]Binding(TestId){bound(1, "a" ** encoded_len)};
    try testing.expectEqual(
        Resolution(TestId).unknown,
        resolve(TestId, "z" ** encoded_len, &active),
    );
}

test "a token from an ended run no longer resolves" {
    const gone = "a" ** encoded_len;
    try testing.expectEqual(Resolution(TestId).unknown, resolve(TestId, gone, &.{}));
}

test "a wrong-length presentation is rejected without hashing" {
    const active = [_]Binding(TestId){bound(1, "a" ** encoded_len)};
    try testing.expectEqual(Resolution(TestId).unknown, resolve(TestId, "short", &active));
    try testing.expectEqual(
        Resolution(TestId).unknown,
        resolve(TestId, "a" ** (encoded_len + 1), &active),
    );
}

test "a prefix of a valid token does not resolve" {
    const real = "a" ** encoded_len;
    const active = [_]Binding(TestId){bound(1, real)};
    try testing.expectEqual(Resolution(TestId).unknown, resolve(TestId, real[0 .. encoded_len - 1], &active));
}

test "hashing is stable and distinguishes tokens" {
    try testing.expectEqual(hash("abc"), hash("abc"));
    try testing.expect(!std.mem.eql(u8, &hash("abc"), &hash("abd")));
}

test "an encoded token is url-safe and has no padding" {
    const encoded = "A" ** encoded_len;
    for (encoded) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => {},
        else => return error.UnexpectedCharacter,
    };
    try testing.expectEqual(@as(usize, 43), encoded_len);
}
