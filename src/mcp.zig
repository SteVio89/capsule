//! The MCP surface: five tools, and the JSON-RPC framing around them.
//!
//! Minimal on purpose. Every tool definition costs context on every turn, forever, so the
//! set is exactly what an agent working one issue needs and nothing else.
//!
//! **The tool descriptions carry the behavioural instructions**, not just parameter docs.
//! Tool definitions are re-sent to the model every turn and never compact away, which
//! makes them the one place an instruction is durable for free — unlike a start-of-session
//! file, which sits precisely in the region long sessions summarise out.
//!
//! There is no `list_ready`: the session is locked to one issue and cannot switch, so a
//! standing list would cost tokens every turn to show work the agent cannot act on. The
//! one real benefit — not filing duplicates — is delivered by `file_issue`'s *response*,
//! at the only moment it matters and at no cost on turns where nothing is filed.
//!
//! And there is deliberately no description-write tool and no route to `open`, `done`, or
//! `archived`. Descriptions and lifecycle decisions are human-authored.

const std = @import("std");

/// Echoed back to whatever the client asks for rather than pinned to one revision: the
/// handshake is a negotiation, and hardcoding a version we happen to know about is how a
/// server ends up refusing a client that would have worked fine.
pub const fallback_protocol_version = "2025-06-18";

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema, written out rather than generated — these are read by a model, and
    /// the wording matters as much as the shape.
    schema: []const u8,
};

pub const tools = [_]Tool{
    .{
        .name = "get_issue",
        .description =
        \\Get the issue this session is working on, plus the project's active memories.
        \\
        \\Call this first, before reading code or making a plan. It takes no arguments:
        \\the session is bound to exactly one issue and you cannot address a different
        \\one. The body is fetched rather than pasted into your prompt, so it reflects
        \\any edits made since the session started — call it again if you suspect the
        \\issue has changed.
        ,
        .schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "set_state",
        .description =
        \\Report where you have got to. Call this on transitions, not at the end.
        \\
        \\  in_progress       you have started work
        \\  blocked           you cannot proceed, and a human needs to look
        \\  ready_for_review  your part is finished
        \\
        \\`comment` is REQUIRED for `blocked` and `ready_for_review`: say what you did,
        \\what you did not do, and what the next person needs to know. Your session
        \\history is not kept after this run ends, so this note and the git branch are
        \\the only things that survive it.
        \\
        \\You cannot set `done` — merging your branch is a human decision, and
        \\`ready_for_review` is how you ask for it.
        ,
        .schema =
        \\{"type":"object","properties":{"state":{"type":"string","enum":["in_progress","blocked","ready_for_review"]},"comment":{"type":"string","description":"Required for blocked and ready_for_review."}},"required":["state"],"additionalProperties":false}
        ,
    },
    .{
        .name = "comment",
        .description =
        \\Add a note to this issue's event log — a decision you made, something you
        \\ruled out, a surprise in the code. The log is what the next run and the human
        \\reviewer both read.
        ,
        .schema =
        \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}
        ,
    },
    .{
        .name = "file_issue",
        .description =
        \\File follow-up work you discovered but should not do now, because it is out of
        \\scope for the issue you are on.
        \\
        \\The response lists existing open issues that look similar. Read it: if one of
        \\them already covers what you filed, say so in a comment on this issue rather
        \\than leaving a duplicate for a human to close.
        \\
        \\What you file is not dispatched to anyone automatically — it waits for a human
        \\to triage it, and you will not see it again.
        ,
        .schema =
        \\{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"}},"required":["title"],"additionalProperties":false}
        ,
    },
    .{
        .name = "propose_memory",
        .description =
        \\Propose something a *future* agent could not work out from the code, the issue,
        \\or the branch. A human reviews proposals before any of them are kept.
        \\
        \\Worth proposing:
        \\  - a decision and its reason: "X not Y, because Z"
        \\  - a trap: "the suite fails under parallel execution"
        \\  - an approach that did not work, and why
        \\  - a convention no tool enforces
        \\
        \\Not worth proposing: what the code does (it can be read), what happened during
        \\this run (that is the event log), progress on this issue (also the event log),
        \\or anyone's stylistic preferences (those are configuration).
        \\
        \\One to three sentences. `anchors` are repo-relative paths the memory depends
        \\on, used to flag it as suspect if they are later deleted or renamed.
        ,
        .schema =
        \\{"type":"object","properties":{"body":{"type":"string"},"anchors":{"type":"array","items":{"type":"string"}}},"required":["body"],"additionalProperties":false}
        ,
    },
};

/// The tool with exactly this name, or null. Returned by value; the strings inside are
/// static.
pub fn findTool(name: []const u8) ?Tool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

// ---------------------------------------------------------------- request framing

pub const Request = struct {
    /// Absent for notifications, which take no response at all.
    id: ?std.json.Value,
    method: []const u8,
    params: std.json.Value,
};

pub const ParseError = error{ BadJson, NoMethod };

/// Parses one JSON-RPC request body. The returned request's strings and values point
/// into the parsed tree, which `arena` owns — they live until the arena is dropped.
pub fn parseRequest(arena: std.mem.Allocator, body: []const u8) ParseError!Request {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return error.BadJson;
    const object = switch (parsed) {
        .object => |o| o,
        else => return error.BadJson,
    };
    const method = switch (object.get("method") orelse return error.NoMethod) {
        .string => |s| s,
        else => return error.NoMethod,
    };
    return .{
        .id = object.get("id"),
        .method = method,
        .params = object.get("params") orelse .null,
    };
}

/// True for JSON-RPC notifications — no id means no reply, and replying anyway is a
/// protocol violation some clients treat as fatal.
pub fn isNotification(request: Request) bool {
    const id = request.id orelse return true;
    return id == .null;
}

/// Echoes a request id back as JSON. JSON-RPC allows integer or string ids; anything
/// else — including a missing id — is written as `null`.
pub fn writeId(w: *std.Io.Writer, id: ?std.json.Value) !void {
    const value = id orelse {
        try w.writeAll("null");
        return;
    };
    switch (value) {
        .integer => |i| try w.print("{d}", .{i}),
        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        else => try w.writeAll("null"),
    }
}

/// Writes a protocol-level JSON-RPC error object — for requests that never reached a
/// tool. A failure the model should react to goes through `writeToolResult` instead.
pub fn writeError(w: *std.Io.Writer, id: ?std.json.Value, code: i32, message: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    try w.writeAll("}}");
}

/// Tool results are text content blocks. `is_error` is how a tool reports a failure the
/// model should see and react to, as opposed to a protocol-level error.
pub fn writeToolResult(w: *std.Io.Writer, id: ?std.json.Value, text: []const u8, is_error: bool) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.encodeJsonString(text, .{}, w);
    try w.print("}}],\"isError\":{}}}}}", .{is_error});
}

/// The `tools/list` response: every tool with its name, description, and input schema,
/// straight from the static `tools` table.
pub fn writeToolList(w: *std.Io.Writer, id: ?std.json.Value) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll(",\"result\":{\"tools\":[");
    for (tools, 0..) |tool, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try std.json.Stringify.encodeJsonString(tool.name, .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.encodeJsonString(tool.description, .{}, w);
        try w.print(",\"inputSchema\":{s}}}", .{tool.schema});
    }
    try w.writeAll("]}}");
}

/// The `initialize` response. `protocol_version` is what `negotiateVersion` settled on;
/// the capabilities are static — tools only.
pub fn writeInitialize(w: *std.Io.Writer, id: ?std.json.Value, protocol_version: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll(",\"result\":{\"protocolVersion\":");
    try std.json.Stringify.encodeJsonString(protocol_version, .{}, w);
    try w.writeAll(
        ",\"capabilities\":{\"tools\":{}}," ++
            "\"serverInfo\":{\"name\":\"capsule\",\"version\":\"0.1.0\"}}}",
    );
}

/// The version the client asked for, or ours if it did not ask.
pub fn negotiateVersion(params: std.json.Value) []const u8 {
    const object = switch (params) {
        .object => |o| o,
        else => return fallback_protocol_version,
    };
    return switch (object.get("protocolVersion") orelse return fallback_protocol_version) {
        .string => |s| if (s.len > 0) s else fallback_protocol_version,
        else => fallback_protocol_version,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "there are exactly five tools, and they are the specified five" {
    // The count is the point: every definition is re-sent every turn, forever.
    try testing.expectEqual(@as(usize, 5), tools.len);
    for ([_][]const u8{ "get_issue", "set_state", "comment", "file_issue", "propose_memory" }) |name| {
        try testing.expect(findTool(name) != null);
    }
    // Deliberately absent — see the module header for why each one is missing.
    for ([_][]const u8{ "list_ready", "set_description", "read_file", "run_command", "search_memory" }) |name| {
        try testing.expect(findTool(name) == null);
    }
}

test "set_state cannot reach a state the agent may not set" {
    const tool = findTool("set_state").?;
    try testing.expect(std.mem.indexOf(u8, tool.schema, "in_progress") != null);
    try testing.expect(std.mem.indexOf(u8, tool.schema, "ready_for_review") != null);
    // Merging is a human decision; the enum is what enforces that at the boundary.
    try testing.expect(std.mem.indexOf(u8, tool.schema, "\"done\"") == null);
    try testing.expect(std.mem.indexOf(u8, tool.schema, "\"archived\"") == null);
}

test "the descriptions carry the behaviour, not just the parameters" {
    // These are load-bearing: they are the only instructions that survive compaction.
    try testing.expect(std.mem.indexOf(u8, findTool("get_issue").?.description, "Call this first") != null);
    try testing.expect(std.mem.indexOf(u8, findTool("set_state").?.description, "REQUIRED") != null);
    try testing.expect(std.mem.indexOf(u8, findTool("file_issue").?.description, "similar") != null);
    try testing.expect(std.mem.indexOf(u8, findTool("propose_memory").?.description, "Not worth proposing") != null);
}

test "every tool's schema is valid json" {
    var a = testArena();
    defer a.deinit();
    for (tools) |tool| {
        _ = std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), tool.schema, .{}) catch {
            std.debug.print("bad schema on {s}\n", .{tool.name});
            return error.InvalidSchema;
        };
    }
}

test "get_issue takes no arguments at all" {
    // The token supplies project and issue, so there is nothing to pass and nothing to
    // get wrong.
    const tool = findTool("get_issue").?;
    try testing.expect(std.mem.indexOf(u8, tool.schema, "\"properties\":{}") != null);
}

test "requests parse, and notifications are recognised" {
    var a = testArena();
    defer a.deinit();

    const call = try parseRequest(a.allocator(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_issue"}}
    );
    try testing.expectEqualStrings("tools/call", call.method);
    try testing.expect(!isNotification(call));

    const note = try parseRequest(a.allocator(),
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    try testing.expect(isNotification(note));
}

test "malformed requests are rejected by code" {
    var a = testArena();
    defer a.deinit();
    try testing.expectError(error.BadJson, parseRequest(a.allocator(), "not json"));
    try testing.expectError(error.BadJson, parseRequest(a.allocator(), "[]"));
    try testing.expectError(error.NoMethod, parseRequest(a.allocator(), "{}"));
    try testing.expectError(error.NoMethod, parseRequest(a.allocator(), "{\"method\":7}"));
}

test "the protocol version is echoed back, not pinned" {
    var a = testArena();
    defer a.deinit();
    const params = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(),
        \\{"protocolVersion":"2099-01-01"}
    , .{});
    try testing.expectEqualStrings("2099-01-01", negotiateVersion(params));
    try testing.expectEqualStrings(fallback_protocol_version, negotiateVersion(.null));
}

test "a string id round-trips as a string, an integer as a number" {
    var buf: [128]u8 = undefined;
    var a = testArena();
    defer a.deinit();

    var w = std.Io.Writer.fixed(&buf);
    try writeId(&w, .{ .string = "abc" });
    try testing.expectEqualStrings("\"abc\"", w.buffered());

    var w2 = std.Io.Writer.fixed(&buf);
    try writeId(&w2, .{ .integer = 42 });
    try testing.expectEqualStrings("42", w2.buffered());
}

test "a tool result is a well-formed content block" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeToolResult(&w, .{ .integer = 3 }, "hello", false);

    var a = testArena();
    defer a.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), w.buffered(), .{});
    const result = parsed.object.get("result").?.object;
    try testing.expectEqualStrings("hello", result.get("content").?.array.items[0].object.get("text").?.string);
    try testing.expectEqual(false, result.get("isError").?.bool);
}

test "the tool list is well-formed json with every tool in it" {
    var buf: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeToolList(&w, .{ .integer = 1 });

    var a = testArena();
    defer a.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), w.buffered(), .{});
    const listed = parsed.object.get("result").?.object.get("tools").?.array;
    try testing.expectEqual(tools.len, listed.items.len);
    // The schema must arrive as an object, not as the string we stored it as.
    try testing.expect(listed.items[0].object.get("inputSchema").? == .object);
}

test "an error response is well-formed" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeError(&w, .{ .integer = 1 }, -32601, "no such method");

    var a = testArena();
    defer a.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), w.buffered(), .{});
    try testing.expectEqual(@as(i64, -32601), parsed.object.get("error").?.object.get("code").?.integer);
}

test "initialize advertises tools and echoes the version" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeInitialize(&w, .{ .integer = 1 }, "2025-06-18");

    var a = testArena();
    defer a.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), w.buffered(), .{});
    const result = parsed.object.get("result").?.object;
    try testing.expectEqualStrings("2025-06-18", result.get("protocolVersion").?.string);
    try testing.expect(result.get("capabilities").?.object.get("tools") != null);
}
