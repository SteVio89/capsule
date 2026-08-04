//! Booting the local qemu VM: where the disk comes from, what proves it, and the machine
//! it is booted as.
//!
//! Everything here is pure or nearly so, which is the point — bash did this with `curl`
//! into `jq` into `shasum` into `unxz` into `sed` into `butane`, and the only part worth
//! reimplementing was the part that decides whether the download is the right one. The
//! downloader is still `curl` and the decompressor is still `xz`; the checksum and the
//! stream metadata moved in-process, because those are where a wrong answer is dangerous
//! rather than merely slow.

const std = @import("std");
const Io = std.Io;

pub const Config = struct {
    vm_host: []const u8,
    vm_port: u16,
    vm_cpus: u16,
    vm_mem: u32,
    /// The qcow2 the VM boots from.
    disk: []const u8,
    /// The rendered ignition config.
    ignition: []const u8,
    /// UEFI firmware, resolved from the qemu binary's own prefix.
    firmware: []const u8,
    qemu: []const u8,
};

/// The butane config the VM is provisioned from.
///
/// Embedded rather than read from `CAPSULE_SHARE`, the way `env init`'s templates are:
/// resolving it at run time made `vm start` depend on the flake wrapper, the Nix store
/// path and the image layout all agreeing, and when the setting was simply absent the
/// path collapsed to `/fcos.bu.tmpl`. `CAPSULE_BUTANE` still overrides it, which is the
/// escape hatch for provisioning a VM differently.
pub const butane_template = @embedFile("template_butane");

/// Fedora CoreOS publishes one metadata document per stream.
pub fn streamUrl(arena: std.mem.Allocator, stream: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "https://builds.coreos.fedoraproject.org/streams/{s}.json",
        .{stream},
    );
}

pub const Artifact = struct {
    location: []const u8,
    sha256: []const u8,

    /// The basename the download is saved under. Taken from the URL so a new build lands
    /// in a new file — resuming a partial download of a *previous* build into the same
    /// name is how a checksum failure becomes permanent.
    pub fn filename(self: Artifact) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, self.location, '/') orelse return self.location;
        return self.location[slash + 1 ..];
    }
};

/// Pulls the aarch64 qemu qcow2.xz entry out of the stream metadata.
///
/// bash reached this with a `jq -r` over a path expression and got the string `null` back
/// when any step was missing, which then flowed on as if it were a URL. Here a missing
/// step is an error with a name.
pub fn parseStream(arena: std.mem.Allocator, body: []const u8) !Artifact {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return error.MalformedStream;

    var node = root;
    for ([_][]const u8{ "architectures", "aarch64", "artifacts", "qemu", "formats", "qcow2.xz", "disk" }) |key| {
        const object = switch (node) {
            .object => |o| o,
            else => return error.MalformedStream,
        };
        node = object.get(key) orelse return error.NoSuchArtifact;
    }

    const disk = switch (node) {
        .object => |o| o,
        else => return error.MalformedStream,
    };
    const location = switch (disk.get("location") orelse return error.NoSuchArtifact) {
        .string => |s| s,
        else => return error.MalformedStream,
    };
    const sha256 = switch (disk.get("sha256") orelse return error.NoSuchArtifact) {
        .string => |s| s,
        else => return error.MalformedStream,
    };
    if (location.len == 0 or sha256.len != 64) return error.MalformedStream;
    return .{ .location = location, .sha256 = sha256 };
}

/// The sha256 of a file, as lowercase hex.
///
/// Read in chunks and hashed as it goes: the download is around a gigabyte, and the point
/// of checking it is defeated by an implementation that needs it all in memory first.
pub fn sha256File(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(arena, "{x}", .{&digest});
}

/// Whether two hex digests match, without leaking which byte differed through timing.
///
/// A published checksum is not a secret and this is not strictly necessary — but the
/// comparison is one call either way, and a constant-time one never has to be revisited.
pub fn digestsMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= std.ascii.toLower(x) ^ std.ascii.toLower(y);
    return diff == 0;
}

/// The butane source: the shipped template with the user's public key in it.
///
/// The key is substituted rather than templated by a shell, so a key file containing a
/// `|` no longer breaks the `sed` expression bash used as a delimiter.
pub fn renderIgnitionSource(
    arena: std.mem.Allocator,
    template: []const u8,
    ssh_key: []const u8,
) ![]const u8 {
    const key = std.mem.trim(u8, ssh_key, " \t\r\n");
    if (key.len == 0) return error.EmptySshKey;
    // The key sits inside a double-quoted YAML scalar, so a quote in it would end the
    // scalar and butane would reject the document — or worse, accept a different one.
    if (std.mem.indexOfAny(u8, key, "\"\\\n\r") != null) return error.UnusableSshKey;

    const placeholder = "@SSH_KEY@";
    if (std.mem.indexOf(u8, template, placeholder) == null) return error.NoPlaceholder;

    const size = std.mem.replacementSize(u8, template, placeholder, key);
    const out = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, template, placeholder, key, out);
    return out;
}

/// The UEFI firmware qemu needs, found next to the qemu binary rather than at a fixed
/// path: it is installed under the Nix store prefix that built this qemu.
pub fn firmwarePath(arena: std.mem.Allocator, qemu_real_path: []const u8) ![]const u8 {
    const bin_dir = std.fs.path.dirname(qemu_real_path) orelse return error.NoFirmware;
    const prefix = std.fs.path.dirname(bin_dir) orelse return error.NoFirmware;
    return std.fmt.allocPrint(arena, "{s}/share/qemu/edk2-aarch64-code.fd", .{prefix});
}

/// The machine capsule boots.
///
/// `-nographic` because the VM's console is the terminal this runs in, and
/// `hostfwd` because the guest is on qemu's user network — the only port that ever needs
/// to reach it is ssh, and forwarding exactly that is what keeps it off the LAN.
pub fn qemuArgs(arena: std.mem.Allocator, cfg: Config) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{
        cfg.qemu,
        "-machine",
        "virt,accel=hvf",
        "-cpu",
        "host",
        "-rtc",
        "base=utc,clock=host",
        "-smp",
        try std.fmt.allocPrint(arena, "{d}", .{cfg.vm_cpus}),
        "-m",
        try std.fmt.allocPrint(arena, "{d}", .{cfg.vm_mem}),
        "-nographic",
        "-bios",
        cfg.firmware,
        "-drive",
        try std.fmt.allocPrint(
            arena,
            "if=virtio,file={s},discard=unmap,detect-zeroes=unmap",
            .{cfg.disk},
        ),
        "-fw_cfg",
        try std.fmt.allocPrint(
            arena,
            "name=opt/com.coreos/config,file={s}",
            .{cfg.ignition},
        ),
        "-nic",
        try std.fmt.allocPrint(
            arena,
            "user,hostfwd=tcp::{d}-:22",
            .{cfg.vm_port},
        ),
    });
    return args.toOwnedSlice(arena);
}

/// The host key entry ssh records for the VM, so a rebuilt disk does not read as an
/// attack the next time anything connects.
pub fn knownHostsEntry(arena: std.mem.Allocator, vm_host: []const u8, vm_port: u16) ![]const u8 {
    const at = std.mem.indexOfScalar(u8, vm_host, '@');
    const host = if (at) |i| vm_host[i + 1 ..] else vm_host;
    return std.fmt.allocPrint(arena, "[{s}]:{d}", .{ host, vm_port });
}

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

const example = Config{
    .vm_host = "core@localhost",
    .vm_port = 2222,
    .vm_cpus = 4,
    .vm_mem = 6144,
    .disk = "/home/me/.local/share/capsule/fcos.qcow2",
    .ignition = "/home/me/.local/share/capsule/fcos.ign",
    .firmware = "/nix/store/abc-qemu/share/qemu/edk2-aarch64-code.fd",
    .qemu = "/nix/store/abc-qemu/bin/qemu-system-aarch64",
};

const stream_json =
    \\{"stream":"stable","architectures":{"aarch64":{"artifacts":{"qemu":{"formats":{
    \\"qcow2.xz":{"disk":{"location":"https://builds.coreos.fedoraproject.org/x/fedora-coreos-42-qemu.aarch64.qcow2.xz",
    \\"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}}}}}}}
;

test "the aarch64 qemu disk is found in the stream metadata" {
    var a = testArena();
    defer a.deinit();

    const got = try parseStream(a.allocator(), stream_json);
    try testing.expectEqualStrings(
        "https://builds.coreos.fedoraproject.org/x/fedora-coreos-42-qemu.aarch64.qcow2.xz",
        got.location,
    );
    try testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        got.sha256,
    );
    try testing.expectEqualStrings("fedora-coreos-42-qemu.aarch64.qcow2.xz", got.filename());
}

test "a missing artifact is an error, not the string null flowing on as a url" {
    var a = testArena();
    defer a.deinit();

    // bash's `jq -r` yielded the literal text "null" here, which then reached `curl`.
    try testing.expectError(
        error.NoSuchArtifact,
        parseStream(a.allocator(), "{\"architectures\":{}}"),
    );
    try testing.expectError(error.MalformedStream, parseStream(a.allocator(), "not json"));
    try testing.expectError(error.MalformedStream, parseStream(a.allocator(), "{\"architectures\":7}"));
}

test "a digest of the wrong length is refused before anything is booted" {
    var a = testArena();
    defer a.deinit();
    const short =
        \\{"architectures":{"aarch64":{"artifacts":{"qemu":{"formats":{
        \\"qcow2.xz":{"disk":{"location":"https://x/y.xz","sha256":"abc"}}}}}}}}
    ;
    try testing.expectError(error.MalformedStream, parseStream(a.allocator(), short));
}

test "digests compare case-insensitively and reject a mismatch" {
    try testing.expect(digestsMatch("ABCdef01", "abcDEF01"));
    try testing.expect(!digestsMatch("abcdef01", "abcdef02"));
    try testing.expect(!digestsMatch("abcdef01", "abcdef0"));
    try testing.expect(digestsMatch("", ""));
}

test "the ssh key is substituted into the butane template" {
    var a = testArena();
    defer a.deinit();

    const template = "users:\n  - ssh_authorized_keys:\n      - \"@SSH_KEY@\"\n";
    const got = try renderIgnitionSource(a.allocator(), template, "ssh-ed25519 AAAAC3Nz me@host\n");
    try testing.expect(std.mem.indexOf(u8, got, "@SSH_KEY@") == null);
    try testing.expect(std.mem.indexOf(u8, got, "\"ssh-ed25519 AAAAC3Nz me@host\"") != null);
}

test "a key that would end the yaml scalar is refused rather than rendered" {
    var a = testArena();
    defer a.deinit();
    const template = "- \"@SSH_KEY@\"";

    try testing.expectError(error.EmptySshKey, renderIgnitionSource(a.allocator(), template, "   \n"));
    try testing.expectError(
        error.UnusableSshKey,
        renderIgnitionSource(a.allocator(), template, "ssh-ed25519 AAA\" evil: true"),
    );
    try testing.expectError(
        error.NoPlaceholder,
        renderIgnitionSource(a.allocator(), "nothing to fill", "ssh-ed25519 AAA"),
    );
}

test "the firmware is resolved from the qemu binary's own prefix" {
    var a = testArena();
    defer a.deinit();
    try testing.expectEqualStrings(
        "/nix/store/abc-qemu/share/qemu/edk2-aarch64-code.fd",
        try firmwarePath(a.allocator(), "/nix/store/abc-qemu/bin/qemu-system-aarch64"),
    );
    try testing.expectError(error.NoFirmware, firmwarePath(a.allocator(), "qemu-system-aarch64"));
}

test "the guest is reachable on the forwarded ssh port and nothing else" {
    var a = testArena();
    defer a.deinit();

    const line = try std.mem.join(a.allocator(), " ", try qemuArgs(a.allocator(), example));
    try testing.expect(std.mem.indexOf(u8, line, "user,hostfwd=tcp::2222-:22") != null);
    try testing.expect(std.mem.indexOf(u8, line, "-nographic") != null);
    try testing.expect(std.mem.indexOf(u8, line, "accel=hvf") != null);

    // No other forward, and no bridged or tap networking that would put it on the LAN.
    try testing.expect(std.mem.indexOf(u8, line, "bridge") == null);
    try testing.expect(std.mem.indexOf(u8, line, "tap") == null);
}

test "the disk, the ignition and the firmware all reach qemu" {
    var a = testArena();
    defer a.deinit();

    const line = try std.mem.join(a.allocator(), " ", try qemuArgs(a.allocator(), example));
    try testing.expect(std.mem.indexOf(u8, line, example.disk) != null);
    try testing.expect(std.mem.indexOf(u8, line, "name=opt/com.coreos/config") != null);
    try testing.expect(std.mem.indexOf(u8, line, example.ignition) != null);
    try testing.expect(std.mem.indexOf(u8, line, example.firmware) != null);
    try testing.expect(std.mem.indexOf(u8, line, "-smp 4") != null);
    try testing.expect(std.mem.indexOf(u8, line, "-m 6144") != null);
}

test "every qemu argument stays its own word" {
    var a = testArena();
    defer a.deinit();

    // The argv goes to the process directly, with no shell between — so a path with a
    // space in it is one argument here and would have been two through bash.
    var spaced = example;
    spaced.disk = "/home/my machine/fcos.qcow2";
    const argv = try qemuArgs(a.allocator(), spaced);

    var found = false;
    for (argv) |arg| {
        if (std.mem.indexOf(u8, arg, "/home/my machine/fcos.qcow2") != null) found = true;
    }
    try testing.expect(found);
}

test "the known-hosts entry names the host and port ssh recorded" {
    var a = testArena();
    defer a.deinit();
    try testing.expectEqualStrings(
        "[localhost]:2222",
        try knownHostsEntry(a.allocator(), "core@localhost", 2222),
    );
    try testing.expectEqualStrings(
        "[10.0.0.5]:22",
        try knownHostsEntry(a.allocator(), "10.0.0.5", 22),
    );
}

test "the sha256 of a real file matches a known digest" {
    var a = testArena();
    defer a.deinit();
    const arena = a.allocator();

    // "abc" has a published NIST digest, so what is under test is the plumbing —
    // chunked reads, offsets, hex formatting — and not sha256 itself.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_path = try std.fmt.allocPrint(
        arena,
        ".zig-cache/tmp/{s}/probe",
        .{tmp.sub_path},
    );

    var file = try Io.Dir.cwd().createFile(testing.io, file_path, .{});
    {
        defer file.close(testing.io);
        var buf: [64]u8 = undefined;
        var w = file.writer(testing.io, &buf);
        try w.interface.writeAll("abc");
        try w.interface.flush();
    }

    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        try sha256File(arena, testing.io, file_path),
    );
}
