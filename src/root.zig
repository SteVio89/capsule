//! capsuled's core: everything the daemon, the client, and the board share.
//!
//! The rule that keeps this testable is that the interesting logic lives in pure
//! functions here — event replay, buffer parsing, prefix resolution, the socket envelope —
//! and the IO lives in thin wrappers around them.

pub const id = @import("id.zig");
pub const model = @import("model.zig");
pub const replay = @import("replay.zig");
pub const protocol = @import("protocol.zig");
pub const sqlite = @import("sqlite.zig");
pub const store = @import("store.zig");
pub const paths = @import("paths.zig");
pub const project = @import("project.zig");
pub const editor = @import("editor.zig");
pub const token = @import("token.zig");
pub const mcp = @import("mcp.zig");
pub const seed = @import("seed.zig");
pub const run = @import("run.zig");
pub const buffer = @import("buffer.zig");
pub const memory = @import("memory.zig");
pub const daemon = @import("daemon.zig");
pub const client = @import("client.zig");
pub const world = @import("world.zig");
pub const ssh = @import("ssh.zig");
pub const http = @import("http.zig");
pub const board = @import("board.zig");
pub const tui = struct {
    pub const screen = @import("tui/screen.zig");
    pub const board = @import("tui/board.zig");
    pub const term = @import("tui/term.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
    // refAllDecls references `tui` as a type without analysing what is inside it, so the
    // nested modules' tests would never be compiled in. Name them directly.
    _ = @import("tui/screen.zig");
    _ = @import("tui/board.zig");
    _ = @import("tui/term.zig");
}
