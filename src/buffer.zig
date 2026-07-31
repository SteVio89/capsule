//! The `rebase -i`-style review buffer, parsed.
//!
//! One parser for both triage and memory review. The verb vocabulary differs, so it is a
//! parameter — not a reason to fork this into two files that would drift apart.
//!
//! Two rules are load-bearing and deliberately diverge from `rebase -i`:
//!
//!   - **The default verb is `keep`**, so saving an unread buffer is a no-op. That matches
//!     the editor primitive's "unchanged means nothing happened".
//!   - **A deleted line means keep, not delete.** Accidentally removing a line must never
//!     destroy data, which is exactly what `rebase -i` does and exactly what nobody wants
//!     from a backlog.
//!
//! And parsing never half-applies: this returns a whole plan or an error. Half-applied
//! triage has no clean recovery.
//!
//! Only **column 0** is structural. Bodies come from agents, and an agent's ordinary
//! markdown ("## Steps to reproduce", an HTML comment) must neither wedge the parse nor
//! forge a verb — so `renderBody` indents content by two spaces on the way out, and the
//! parser strips that indent and treats indented lines as pure body on the way back.

const std = @import("std");

/// The indent `renderBody` applies and the parser removes. Two spaces: invisible enough
/// to edit comfortably, and enough to move agent text out of the structural column.
pub const body_indent = "  ";

pub const Entry = struct {
    verb: []const u8,
    /// The short id from the heading.
    id: []const u8,
    title: []const u8,
    /// Everything under the heading, comments stripped. Edited freely by the user, and
    /// applied along with the verb.
    body: []const u8,
};

pub const Error = union(enum) {
    unknown_verb: struct { line: usize, verb: []const u8 },
    unknown_id: struct { line: usize, id: []const u8 },
    duplicate_id: struct { line: usize, id: []const u8 },
    malformed_heading: struct { line: usize },
};

pub const Result = union(enum) {
    ok: []Entry,
    malformed: Error,
};

pub const Options = struct {
    /// The verbs this buffer accepts. First one is the default.
    verbs: []const []const u8,
    /// Only these ids may appear. Captured when the buffer is spawned, so an issue filed
    /// by a running agent while the buffer is open stays untouched rather than being
    /// silently dropped.
    expected: []const []const u8,
};

/// Pure: buffer text in, a plan or an error out.
pub fn parse(arena: std.mem.Allocator, text: []const u8, options: Options) !Result {
    var entries: std.ArrayList(Entry) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;

    var body: std.ArrayList(u8) = .empty;
    var current: ?Entry = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;

    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");

        // `#` is a markdown heading, not a comment, so the context lines are HTML
        // comments and are stripped here. Column 0 only: an indented `<!--` is body
        // text that `renderBody` escaped, and eating it would corrupt what it carries.
        if (std.mem.startsWith(u8, line, "<!--")) continue;

        if (!std.mem.startsWith(u8, line, "## ")) {
            if (current != null) {
                // Undo the render indent, and only the render indent — deeper
                // indentation belongs to the content itself.
                const unindented = if (std.mem.startsWith(u8, line, body_indent))
                    line[body_indent.len..]
                else
                    line;
                try body.appendSlice(arena, unindented);
                try body.append(arena, '\n');
            }
            continue;
        }

        if (current) |*entry| {
            entry.body = trimBlank(body.items);
            try entries.append(arena, entry.*);
            body = .empty;
        }

        var rest = std.mem.trimStart(u8, line["## ".len..], " ");
        const verb_end = std.mem.indexOfAny(u8, rest, " \t") orelse
            return .{ .malformed = .{ .malformed_heading = .{ .line = line_no } } };
        const verb = rest[0..verb_end];

        var known = false;
        for (options.verbs) |candidate| {
            if (std.mem.eql(u8, candidate, verb)) known = true;
        }
        if (!known) return .{ .malformed = .{ .unknown_verb = .{ .line = line_no, .verb = verb } } };

        rest = std.mem.trimStart(u8, rest[verb_end..], " \t");
        const id_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const id = rest[0..id_end];
        if (id.len == 0) return .{ .malformed = .{ .malformed_heading = .{ .line = line_no } } };

        var expected = false;
        for (options.expected) |candidate| {
            if (std.mem.eql(u8, candidate, id)) expected = true;
        }
        if (!expected) return .{ .malformed = .{ .unknown_id = .{ .line = line_no, .id = id } } };

        for (seen.items) |previous| {
            if (std.mem.eql(u8, previous, id)) {
                return .{ .malformed = .{ .duplicate_id = .{ .line = line_no, .id = id } } };
            }
        }
        try seen.append(arena, id);

        current = .{
            .verb = verb,
            .id = id,
            .title = std.mem.trim(u8, rest[id_end..], " \t"),
            .body = "",
        };
    }

    if (current) |*entry| {
        entry.body = trimBlank(body.items);
        try entries.append(arena, entry.*);
    }

    return .{ .ok = try entries.toOwnedSlice(arena) };
}

/// An entry the user deleted from the buffer entirely is *kept*, not dropped. This
/// returns the ids that never appeared, so the caller can leave them exactly as they were.
pub fn missing(arena: std.mem.Allocator, entries: []const Entry, expected: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (expected) |id| {
        var found = false;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.id, id)) found = true;
        }
        if (!found) try out.append(arena, id);
    }
    return out.toOwnedSlice(arena);
}

/// Writes `text` with every line pushed out of the structural column. The inverse of the
/// unindent in `parse`: agent-authored markdown round-trips byte for byte instead of
/// being read as headings or comments.
pub fn renderBody(w: *std.Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            try w.writeAll(body_indent);
            try w.writeAll(line);
        }
        try w.writeAll("\n");
    }
}

/// One human-readable line naming the parse error and where it happened — what the CLI
/// prints before re-opening the buffer. Allocated in `arena`, which owns it.
pub fn describe(arena: std.mem.Allocator, err: Error) ![]const u8 {
    return switch (err) {
        .unknown_verb => |e| std.fmt.allocPrint(arena, "line {d}: '{s}' is not a verb here", .{ e.line, e.verb }),
        .unknown_id => |e| std.fmt.allocPrint(arena, "line {d}: {s} was not in this buffer", .{ e.line, e.id }),
        .duplicate_id => |e| std.fmt.allocPrint(arena, "line {d}: {s} appears twice", .{ e.line, e.id }),
        .malformed_heading => |e| std.fmt.allocPrint(arena, "line {d}: expected '## <verb> <id> <title>'", .{e.line}),
    };
}

fn trimBlank(text: []const u8) []const u8 {
    // Newlines only: the edges to drop are blank lines, and trimming spaces here would
    // eat real indentation off a body's first or last line.
    return std.mem.trim(u8, text, "\r\n");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const triage_verbs = [_][]const u8{ "keep", "accept", "reject" };
const memory_verbs = [_][]const u8{ "keep", "activate", "discard", "deactivate" };

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

fn triage(a: std.mem.Allocator, text: []const u8, expected: []const []const u8) !Result {
    return parse(a, text, .{ .verbs = &triage_verbs, .expected = expected });
}

test "a buffer parses into verbs, ids, titles and bodies" {
    var a = testArena();
    defer a.deinit();
    const result = try triage(a.allocator(),
        \\<!-- capsule triage. verbs: keep | accept | reject -->
        \\
        \\## accept 018f2a1c  Rate limiter drops burst traffic
        \\Body as filed by the agent.
        \\Second line.
        \\
        \\## reject 018f2a3d  Refactor everything
        \\Too vague.
    , &.{ "018f2a1c", "018f2a3d" });

    const entries = result.ok;
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("accept", entries[0].verb);
    try testing.expectEqualStrings("018f2a1c", entries[0].id);
    try testing.expectEqualStrings("Rate limiter drops burst traffic", entries[0].title);
    try testing.expectEqualStrings("Body as filed by the agent.\nSecond line.", entries[0].body);
    try testing.expectEqualStrings("reject", entries[1].verb);
    try testing.expectEqualStrings("Too vague.", entries[1].body);
}

test "an unread buffer is a no-op: every verb is keep" {
    var a = testArena();
    defer a.deinit();
    const result = try triage(a.allocator(),
        \\## keep 018f2a1c  Something
        \\Body.
    , &.{"018f2a1c"});
    try testing.expectEqualStrings("keep", result.ok[0].verb);
}

test "a deleted entry is kept, not dropped" {
    var a = testArena();
    defer a.deinit();
    // This is the divergence from `rebase -i` that matters: removing a line by accident
    // must never destroy anything.
    const result = try triage(a.allocator(),
        \\## accept 018f2a1c  Kept one
    , &.{ "018f2a1c", "018f2a3d" });

    const gone = try missing(a.allocator(), result.ok, &.{ "018f2a1c", "018f2a3d" });
    try testing.expectEqual(@as(usize, 1), gone.len);
    try testing.expectEqualStrings("018f2a3d", gone[0]);
}

test "an unknown verb is refused, and nothing is applied" {
    var a = testArena();
    defer a.deinit();
    const result = try triage(a.allocator(),
        \\## accept 018f2a1c  Fine
        \\## delete 018f2a3d  Not a verb here
    , &.{ "018f2a1c", "018f2a3d" });
    // The whole buffer fails: the first entry is not applied on its own.
    try testing.expectEqualStrings("delete", result.malformed.unknown_verb.verb);
    try testing.expectEqual(@as(usize, 2), result.malformed.unknown_verb.line);
}

test "an id that was not in the buffer at spawn is refused" {
    var a = testArena();
    defer a.deinit();
    // An agent filing an issue while the buffer is open must not be swept up by it.
    const result = try triage(a.allocator(),
        \\## accept 018fbeef  Filed while you were editing
    , &.{"018f2a1c"});
    try testing.expectEqualStrings("018fbeef", result.malformed.unknown_id.id);
}

test "a duplicated id is refused rather than applied twice" {
    var a = testArena();
    defer a.deinit();
    const result = try triage(a.allocator(),
        \\## accept 018f2a1c  One
        \\## reject 018f2a1c  The same one again
    , &.{"018f2a1c"});
    try testing.expectEqualStrings("018f2a1c", result.malformed.duplicate_id.id);
}

test "a malformed heading is refused" {
    var a = testArena();
    defer a.deinit();
    for ([_][]const u8{ "## accept", "## accept  ", "##" }) |text| {
        const result = try triage(a.allocator(), text, &.{"018f2a1c"});
        switch (result) {
            .malformed => {},
            .ok => |entries| {
                // "##" alone is not a heading at all, so it is body text.
                try testing.expectEqual(@as(usize, 0), entries.len);
            },
        }
    }
}

test "an empty buffer yields nothing to do" {
    var a = testArena();
    defer a.deinit();
    const result = try triage(a.allocator(), "", &.{"018f2a1c"});
    try testing.expectEqual(@as(usize, 0), result.ok.len);
}

test "context comments never become body text" {
    var a = testArena();
    defer a.deinit();
    const result = try triage(a.allocator(),
        \\<!-- capsule triage -->
        \\<!-- save to apply. empty file aborts. -->
        \\## accept 018f2a1c  Title
        \\Real body.
    , &.{"018f2a1c"});
    try testing.expectEqualStrings("Real body.", result.ok[0].body);
}

test "an agent body full of markup round-trips through render and parse" {
    var a = testArena();
    defer a.deinit();

    // The hostile-but-ordinary case: markdown headings and an HTML comment, exactly what
    // a well-meaning agent writes into a filed issue. Rendered they are indented; parsed
    // back they are content, not structure.
    const body = "## Steps to reproduce\n<!-- not a capsule comment -->\nplain line";
    var out: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(a.allocator(), &out);
    try w.writer.writeAll("## keep 018f2a1c  Title\n");
    try renderBody(&w.writer, body);

    const result = try triage(a.allocator(), w.written(), &.{"018f2a1c"});
    const entries = result.ok;
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings(body, entries[0].body);
}

test "deeper indentation than the render indent survives untouched" {
    var a = testArena();
    defer a.deinit();
    // A code block indented four spaces renders as six and comes back as four.
    const body = "    indented code";
    var out: std.ArrayList(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(a.allocator(), &out);
    try w.writer.writeAll("## keep 018f2a1c  Title\n");
    try renderBody(&w.writer, body);
    const result = try triage(a.allocator(), w.written(), &.{"018f2a1c"});
    try testing.expectEqualStrings(body, result.ok[0].body);
}

test "the same parser takes the memory vocabulary" {
    var a = testArena();
    defer a.deinit();
    // Parameterised, not forked: two parsers would drift, and the divergence would be in
    // exactly the rules that protect against data loss.
    const result = try parse(a.allocator(),
        \\## activate 018f3b2c  Test suite fails under parallel execution
        \\anchors: test/run.sh
        \\Body as proposed.
        \\
        \\## deactivate 018e91aa  An older one, to free a slot
    , .{ .verbs = &memory_verbs, .expected = &.{ "018f3b2c", "018e91aa" } });

    try testing.expectEqualStrings("activate", result.ok[0].verb);
    try testing.expectEqualStrings("deactivate", result.ok[1].verb);
    try testing.expect(std.mem.indexOf(u8, result.ok[0].body, "anchors: test/run.sh") != null);
}

test "a triage verb is not accepted in a memory buffer" {
    var a = testArena();
    defer a.deinit();
    const result = try parse(a.allocator(),
        \\## reject 018f3b2c  Wrong vocabulary
    , .{ .verbs = &memory_verbs, .expected = &.{"018f3b2c"} });
    try testing.expectEqualStrings("reject", result.malformed.unknown_verb.verb);
}

test "errors describe themselves in terms a person can act on" {
    var a = testArena();
    defer a.deinit();
    const result = try triage(a.allocator(), "## nope 018f2a1c  x", &.{"018f2a1c"});
    const text = try describe(a.allocator(), result.malformed);
    try testing.expect(std.mem.indexOf(u8, text, "line 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "nope") != null);
}

test "a body with blank lines keeps its shape but not its edges" {
    var a = testArena();
    defer a.deinit();
    const result = try triage(a.allocator(),
        \\## keep 018f2a1c  Title
        \\
        \\First paragraph.
        \\
        \\Second paragraph.
        \\
    , &.{"018f2a1c"});
    try testing.expectEqualStrings("First paragraph.\n\nSecond paragraph.", result.ok[0].body);
}
