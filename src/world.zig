//! The daemon's model of the world: VM up, disk, containers, branches, image freshness.

const std = @import("std");

/// One `key<TAB>value` line per fact. The script travels inside the ssh remote command
/// (see `ssh.probeArgs`) and the daemon parses its output — a shape both sides can be
/// read and checked by eye, which matters more here than compactness.
///
/// **Disk is measured at `/var`, never `/`.** On Fedora CoreOS `/` is a composefs: a
/// read-only overlay of a few megabytes, which the board faithfully reported as "0 GB of
/// 0 GB" for as long as it existed. Everything that actually consumes space is under
/// `/var` — podman's images and containers in `/var/lib/containers`, the replicas in
/// `/var/home/core/capsule`.
pub const probe_script =
    \\printf 'uptime\t%s\n' "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
    \\df -P /var | awk 'NR==2 {printf "disk_used\t%s\ndisk_total\t%s\n", $3*1024, $2*1024}'
    \\podman ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null |
    \\  while IFS="$(printf '\t')" read -r n i; do printf 'container\t%s\t%s\n' "$n" "$i"; done
    \\for d in ~/capsule/*/; do
    \\  [ -d "$d/.git" ] || continue
    \\  p=$(basename "$d")
    \\  base=$(git -C "$d" for-each-ref --format='^%(refname)' refs/heads 2>/dev/null | grep -v '^\^refs/heads/capsule/')
    \\  git -C "$d" for-each-ref --format='%(refname:short)' refs/heads/capsule/ 2>/dev/null |
    \\    while read -r b; do
    \\      n=$(git -C "$d" rev-list --count "$b" $base 2>/dev/null || echo 0)
    \\      printf 'branch\t%s\t%s\t%s\n' "$p" "$b" "$n"
    \\    done
    \\done
    \\printf 'image\t%s\n' "$(podman image inspect --format '{{.Digest}}' "$CAPSULE_IMAGE" 2>/dev/null || echo none)"
;

pub const Container = struct {
    name: []const u8,
    image: []const u8,
};

pub const Branch = struct {
    project: []const u8,
    name: []const u8,
    commits: u64,
};

pub const Snapshot = struct {
    /// False means the probe never ran. Every other field is then meaningless, and the
    /// dashboard must say "unreachable" rather than showing stale numbers as current.
    reachable: bool = false,
    observed_at_ms: i64 = 0,
    uptime_s: ?u64 = null,
    disk_used: ?u64 = null,
    disk_total: ?u64 = null,
    image_digest: ?[]const u8 = null,
    containers: []const Container = &.{},
    branches: []const Branch = &.{},
};

/// Unknown keys and malformed lines are skipped rather than failing the whole probe: a
/// VM running a slightly older script should degrade to fewer facts, not to none.
pub fn parseProbe(arena: std.mem.Allocator, blob: []const u8, observed_at_ms: i64) !Snapshot {
    var containers: std.ArrayList(Container) = .empty;
    var branches: std.ArrayList(Branch) = .empty;

    var snapshot = Snapshot{ .reachable = true, .observed_at_ms = observed_at_ms };

    var lines = std.mem.splitScalar(u8, blob, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;

        var fields = std.mem.splitScalar(u8, trimmed, '\t');
        const key = fields.next() orelse continue;

        if (std.mem.eql(u8, key, "uptime")) {
            snapshot.uptime_s = parseU64(fields.next());
        } else if (std.mem.eql(u8, key, "disk_used")) {
            snapshot.disk_used = parseU64(fields.next());
        } else if (std.mem.eql(u8, key, "disk_total")) {
            snapshot.disk_total = parseU64(fields.next());
        } else if (std.mem.eql(u8, key, "image")) {
            const digest = fields.next() orelse continue;
            snapshot.image_digest = if (std.mem.eql(u8, digest, "none")) null else digest;
        } else if (std.mem.eql(u8, key, "container")) {
            const name = fields.next() orelse continue;
            const image = fields.next() orelse continue;
            if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(image)) continue;
            try containers.append(arena, .{ .name = name, .image = image });
        } else if (std.mem.eql(u8, key, "branch")) {
            const project = fields.next() orelse continue;
            const name = fields.next() orelse continue;
            const commits = parseU64(fields.next()) orelse continue;
            if (!std.unicode.utf8ValidateSlice(project) or !std.unicode.utf8ValidateSlice(name)) continue;
            try branches.append(arena, .{ .project = project, .name = name, .commits = commits });
        }
    }

    snapshot.containers = try containers.toOwnedSlice(arena);
    snapshot.branches = try branches.toOwnedSlice(arena);
    return snapshot;
}

fn parseU64(text: ?[]const u8) ?u64 {
    const t = text orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, t, " "), 10) catch null;
}

const testing = std.testing;

fn parse(a: std.mem.Allocator, blob: []const u8) !Snapshot {
    return parseProbe(a, blob, 1234);
}

test "a full probe parses every fact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const blob =
        "uptime\t86400\n" ++
        "disk_used\t1048576\n" ++
        "disk_total\t85899345920\n" ++
        "container\tcapsule-018f2a1c\tghcr.io/x/capsule:latest\n" ++
        "branch\tcapsule-abc123\tcapsule/018f2a1c\t7\n" ++
        "branch\tcapsule-abc123\tcapsule/018f2a3d\t0\n" ++
        "image\tsha256:deadbeef\n";

    const s = try parse(arena.allocator(), blob);
    try testing.expect(s.reachable);
    try testing.expectEqual(@as(i64, 1234), s.observed_at_ms);
    try testing.expectEqual(@as(u64, 86400), s.uptime_s.?);
    try testing.expectEqual(@as(u64, 1048576), s.disk_used.?);
    try testing.expectEqualStrings("sha256:deadbeef", s.image_digest.?);

    try testing.expectEqual(@as(usize, 1), s.containers.len);
    try testing.expectEqualStrings("capsule-018f2a1c", s.containers[0].name);

    try testing.expectEqual(@as(usize, 2), s.branches.len);
    try testing.expectEqualStrings("capsule/018f2a1c", s.branches[0].name);
    try testing.expectEqual(@as(u64, 7), s.branches[0].commits);
    try testing.expectEqual(@as(u64, 0), s.branches[1].commits);
}

test "an empty probe is reachable but knows nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(), "");
    try testing.expect(s.reachable);
    try testing.expectEqual(@as(?u64, null), s.uptime_s);
    try testing.expectEqual(@as(usize, 0), s.containers.len);
}

test "malformed lines are skipped, not fatal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const blob =
        "garbage with no tab\n" ++
        "uptime\tnot-a-number\n" ++
        "container\tonly-a-name\n" ++ // missing image
        "branch\tproj\tcapsule/x\n" ++ // missing count
        "unknown_key\tvalue\n" ++
        "\n" ++
        "disk_used\t42\n";

    const s = try parse(arena.allocator(), blob);
    try testing.expectEqual(@as(?u64, null), s.uptime_s);
    try testing.expectEqual(@as(usize, 0), s.containers.len);
    try testing.expectEqual(@as(usize, 0), s.branches.len);
    try testing.expectEqual(@as(u64, 42), s.disk_used.?);
}

test "a missing image digest reads as absent, not as the string none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(), "image\tnone\n");
    try testing.expectEqual(@as(?[]const u8, null), s.image_digest);
}

test "CRLF from a probe does not corrupt the last field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(), "uptime\t99\r\ndisk_used\t7\r\n");
    try testing.expectEqual(@as(u64, 99), s.uptime_s.?);
    try testing.expectEqual(@as(u64, 7), s.disk_used.?);
}

test "an unreachable VM is a normal state, not an error" {
    const s = Snapshot{};
    try testing.expect(!s.reachable);
    try testing.expectEqual(@as(usize, 0), s.branches.len);
}
