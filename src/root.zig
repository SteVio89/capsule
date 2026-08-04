//! capsuled's core: everything the daemon, the client, and the board share.

pub const id = @import("id.zig");
pub const config = @import("config.zig");
pub const model = @import("model.zig");
pub const replay = @import("replay.zig");
pub const protocol = @import("protocol.zig");
pub const api = @import("api.zig");
pub const exec = @import("exec.zig");
pub const git = @import("git.zig");
pub const flake = @import("flake.zig");
pub const template = @import("template.zig");
pub const cli = @import("cli.zig");
pub const cmd = @import("cmd.zig");
pub const store = @import("store.zig");
pub const paths = @import("paths.zig");
pub const project = @import("project.zig");
pub const editor = @import("editor.zig");
pub const token = @import("token.zig");
pub const mcp = @import("mcp.zig");
pub const seed = @import("seed.zig");
pub const run = @import("run.zig");
pub const vm = @import("vm.zig");
pub const buffer = @import("buffer.zig");
pub const memory = @import("memory.zig");
pub const daemon = @import("daemon.zig");
pub const client = @import("client.zig");
pub const world = @import("world.zig");
pub const ssh = @import("ssh.zig");
pub const http = @import("http.zig");
pub const board = @import("board.zig");
pub const picker = @import("picker.zig");
pub const tui = struct {
    pub const screen = @import("tui/screen.zig");
    pub const board = @import("tui/board.zig");
    pub const term = @import("tui/term.zig");
    pub const list = @import("tui/list.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tui/screen.zig");
    _ = @import("tui/board.zig");
    _ = @import("tui/term.zig");
    _ = @import("tui/list.zig");
}
