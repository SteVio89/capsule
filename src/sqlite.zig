//! A thin typed wrapper over the system libsqlite3.
//!
//! Not a vendored amalgamation and not a package dependency: a `build.zig.zon` entry
//! would force the Nix build through a fixed-output derivation with a hash to regenerate
//! on every bump, and every third-party Zig sqlite wrapper is mid-rewrite for 0.16's
//! stdlib churn. `pkgs.sqlite` plus `linkSystemLibrary` needs no configuration at all.
//!
//! Everything above this file is typed; this is the only place a `?*c.sqlite3` appears.

const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = error{
    CannotOpen,
    Busy,
    Constraint,
    Misuse,
    NotFound,
    SqliteError,
};

/// The two binds that need SQLITE_TRANSIENT live in src/sqlite_shim.c — see the comment
/// there for why they cannot be expressed in Zig. Everything else in sqlite's API is
/// reachable directly.
extern fn capsule_bind_text(stmt: ?*c.sqlite3_stmt, index: c_int, data: [*]const u8, len: u64) c_int;
extern fn capsule_bind_blob(stmt: ?*c.sqlite3_stmt, index: c_int, data: [*]const u8, len: u64) c_int;

fn check(rc: c_int) Error!void {
    return switch (rc) {
        c.SQLITE_OK, c.SQLITE_ROW, c.SQLITE_DONE => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CONSTRAINT => error.Constraint,
        c.SQLITE_MISUSE => error.Misuse,
        c.SQLITE_CANTOPEN => error.CannotOpen,
        else => error.SqliteError,
    };
}

pub const Db = struct {
    handle: ?*c.sqlite3 = null,

    /// `:memory:` gives each test its own database with no file to clean up.
    pub fn open(path: [:0]const u8) Error!Db {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path.ptr,
            &handle,
            // Serialized, not NOMUTEX. The daemon runs an accept loop and a poll thread,
            // and zig's test runner runs tests in parallel — an unserialized connection
            // turns both into a race for no measurable gain at this scale.
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX,
            null,
        );
        if (rc != c.SQLITE_OK) {
            _ = c.sqlite3_close(handle);
            return error.CannotOpen;
        }
        var db = Db{ .handle = handle };
        // WAL so a reader never blocks the writer. Best-effort: some filesystems refuse
        // WAL, and the rollback journal is merely slower, not wrong.
        db.exec("PRAGMA journal_mode=WAL;") catch {};
        // Foreign keys are off by default in sqlite and every reference in the schema
        // assumes they are on — a connection without them is a correctness bug, so this
        // one is not allowed to fail quietly.
        db.exec("PRAGMA foreign_keys=ON;") catch {
            _ = c.sqlite3_close(handle);
            return error.CannotOpen;
        };
        return db;
    }

    /// Closes the connection and nulls the handle. Safe to call on an already-closed Db;
    /// any statements must be finalized first.
    pub fn close(db: *Db) void {
        _ = c.sqlite3_close(db.handle);
        db.handle = null;
    }

    /// For schema and pragmas — statements with no parameters and no rows to read.
    pub fn exec(db: *Db, sql: [:0]const u8) Error!void {
        try check(c.sqlite3_exec(db.handle, sql.ptr, null, null, null));
    }

    /// Compiles one statement. The caller owns the returned `Stmt` and must `finalize`
    /// it before the Db closes.
    pub fn prepare(db: *Db, sql: [:0]const u8) Error!Stmt {
        var handle: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(db.handle, sql.ptr, -1, &handle, null));
        return .{ .handle = handle };
    }

    /// The last error text sqlite produced, for putting in a message a human reads.
    pub fn lastError(db: *Db) []const u8 {
        const msg = c.sqlite3_errmsg(db.handle) orelse return "unknown";
        return std.mem.span(msg);
    }
};

pub const Stmt = struct {
    handle: ?*c.sqlite3_stmt,

    /// Parameters are 1-based, matching sqlite's own numbering rather than quietly
    /// re-basing it and inviting an off-by-one at every call site.
    pub fn bindText(s: Stmt, index: c_int, value: []const u8) Error!void {
        try check(capsule_bind_text(s.handle, index, value.ptr, value.len));
    }

    /// Binds a blob at the 1-based `index`. The value is copied (SQLITE_TRANSIENT, via
    /// the shim), so the caller's slice need not outlive the call.
    pub fn bindBlob(s: Stmt, index: c_int, value: []const u8) Error!void {
        try check(capsule_bind_blob(s.handle, index, value.ptr, value.len));
    }

    /// Binds a 64-bit integer at the 1-based `index`.
    pub fn bindInt(s: Stmt, index: c_int, value: i64) Error!void {
        try check(c.sqlite3_bind_int64(s.handle, index, value));
    }

    /// Binds SQL NULL at the 1-based `index`.
    pub fn bindNull(s: Stmt, index: c_int) Error!void {
        try check(c.sqlite3_bind_null(s.handle, index));
    }

    /// True when a row is available, false when the statement is done.
    pub fn step(s: Stmt) Error!bool {
        const rc = c.sqlite3_step(s.handle);
        try check(rc);
        return rc == c.SQLITE_ROW;
    }

    /// Columns are 0-based, as sqlite has them.
    ///
    /// The slice points into sqlite's own buffer and is invalidated by the next `step`
    /// or `finalize`. Callers that keep it must copy — the store does, into the request
    /// arena.
    pub fn columnText(s: Stmt, index: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(s.handle, index) orelse return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(s.handle, index));
        return ptr[0..len];
    }

    /// Blob variant of `columnText`; the same lifetime caveat applies — the slice is
    /// sqlite's buffer and dies on the next `step` or `finalize`. NULL reads as empty.
    pub fn columnBlob(s: Stmt, index: c_int) []const u8 {
        const ptr = c.sqlite3_column_blob(s.handle, index) orelse return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(s.handle, index));
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    /// The 0-based column as a 64-bit integer; NULL reads as 0. Use `isNull` when the
    /// difference matters.
    pub fn columnInt(s: Stmt, index: c_int) i64 {
        return c.sqlite3_column_int64(s.handle, index);
    }

    /// True when the 0-based column of the current row is SQL NULL — the only way to
    /// tell NULL apart from the empty/zero the column getters return for it.
    pub fn isNull(s: Stmt, index: c_int) bool {
        return c.sqlite3_column_type(s.handle, index) == c.SQLITE_NULL;
    }

    /// Rewinds the statement and clears its bindings so it can be re-run with fresh
    /// parameters. Any error is surfaced by the next `step`, not here.
    pub fn reset(s: Stmt) void {
        _ = c.sqlite3_reset(s.handle);
        _ = c.sqlite3_clear_bindings(s.handle);
    }

    /// Frees the statement and nulls the handle. Invalidates any column slices still
    /// held; safe to call on an already-finalized Stmt.
    pub fn finalize(s: *Stmt) void {
        _ = c.sqlite3_finalize(s.handle);
        s.handle = null;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "open, write, read back" {
    var db = try Db.open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t(a TEXT, b INTEGER, c BLOB);");

    var ins = try db.prepare("INSERT INTO t VALUES(?, ?, ?);");
    defer ins.finalize();
    try ins.bindText(1, "hello");
    try ins.bindInt(2, 42);
    try ins.bindBlob(3, &[_]u8{ 0xde, 0xad });
    try testing.expect(!try ins.step());

    var sel = try db.prepare("SELECT a, b, c FROM t;");
    defer sel.finalize();
    try testing.expect(try sel.step());
    try testing.expectEqualStrings("hello", sel.columnText(0));
    try testing.expectEqual(@as(i64, 42), sel.columnInt(1));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad }, sel.columnBlob(2));
    try testing.expect(!try sel.step());
}

test "a violated constraint is an error, not a silent write" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t(a TEXT PRIMARY KEY);");

    var ins = try db.prepare("INSERT INTO t VALUES('x');");
    defer ins.finalize();
    try testing.expect(!try ins.step());
    ins.reset();
    try testing.expectError(error.Constraint, ins.step());
}

test "null columns are distinguishable from empty ones" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t(a TEXT); INSERT INTO t VALUES(NULL), ('');");

    var sel = try db.prepare("SELECT a FROM t;");
    defer sel.finalize();
    try testing.expect(try sel.step());
    try testing.expect(sel.isNull(0));
    try testing.expect(try sel.step());
    try testing.expect(!sel.isNull(0));
}

test "bad sql surfaces as an error with a message" {
    var db = try Db.open(":memory:");
    defer db.close();
    try testing.expectError(error.SqliteError, db.prepare("SELECT FROM WHERE;"));
    try testing.expect(db.lastError().len > 0);
}
