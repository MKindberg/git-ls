const std = @import("std");

const ts = @import("tree-sitter");
const lsp = @import("lsp");

const lint = @import("lint.zig");

const State = struct {
    config_text: []const u8,
    configs: ConfigMap,

    const Self = @This();
    fn init(config_text: []const u8, configs: ConfigMap) Self {
        return State{
            .config_text = config_text,
            .configs = configs,
        };
    }

    fn parse(self: *Self, content: []const u8) void {
        self.tree = self.parser.parseString(content, null) orelse unreachable;
    }

    fn deinit(self: Self) void {
        _ = self;
    }
};
const Lsp = lsp.Lsp(.{ .state_type = State, .document_type = lsp.TreeSitterDocument });

extern fn tree_sitter_git_config() callconv(.c) *ts.Language;
const Io = std.Io;

const SubSubConfigMap = std.StringHashMap(void);
const SubConfigMap = std.StringHashMap(SubSubConfigMap);
pub const ConfigMap = std.StringHashMap(SubConfigMap);

fn createConfigMap(allocator: std.mem.Allocator, io: std.Io) !ConfigMap {
    var configs = ConfigMap.init(allocator);

    var run_env = try std.process.Environ.empty.createMap(allocator);
    defer run_env.deinit();
    try run_env.put("GIT_CONFIG_NOSYSTEM", "1");
    try run_env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try run_env.put("GIT_CONFIG", "/dev/null");
    const git_result = try std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "git", "help", "--config" }, .environ_map = &run_env });
    if (git_result.term != .exited or git_result.term.exited != 0) {
        std.debug.print("Failed to run git help --config: {s}\n", .{git_result.stderr});
        std.process.exit(1);
    }
    var lines = std.mem.splitScalar(u8, git_result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break; // The list ends with an empty line
        var parts = std.mem.splitScalar(u8, line, '.');

        const p1 = parts.next().?;
        const c1 = try configs.getOrPut(p1);
        if (!c1.found_existing) c1.value_ptr.* = SubConfigMap.init(allocator);

        const p2 = parts.next() orelse continue;
        const c2 = try c1.value_ptr.getOrPut(p2);
        if (!c2.found_existing) c2.value_ptr.* = SubSubConfigMap.init(allocator);

        const p3 = parts.next() orelse continue;
        const c3 = try c2.value_ptr.getOrPut(p3);
        if (!c3.found_existing) c3.value_ptr.* = {};
    }

    return configs;
}

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const server_info = lsp.types.ServerInfo{
        .name = "git-ls",
        .version = "0.1.0",
    };
    var in_buffer: [1024]u8 = undefined;
    var out_buffer: [1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &in_buffer);
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);
    var server = Lsp.init(init.gpa, init.io, &stdin.interface, &stdout.interface, server_info);
    defer server.deinit();

    return server.start(registerCallbacks);
}

fn registerCallbacks(p: Lsp.SetupParameters) Lsp.SetupReturn {
    p.server.registerCallback(.{ .OpenDocument = handleOpenDoc });
    p.server.registerCallback(.{ .ChangeDocument = handleChange });
    p.server.registerCallback(.{ .SaveDocument = handleSave });
    p.server.registerCallback(.{ .CloseDocument = handleCloseDoc });
    p.server.registerCallback(.{ .Formatting = handleFormat });
    p.server.registerCallback(.{ .Hover = handleHover });
}

fn getConfigText(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var run_env = try std.process.Environ.empty.createMap(allocator);
    defer run_env.deinit();
    try run_env.put("GIT_CONFIG_NOSYSTEM", "1");
    try run_env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try run_env.put("GIT_CONFIG", "/dev/null");
    const res = try std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "git", "config", "--help" }, .environ_map = &run_env });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("Failed to run git config --help: {s}\n", .{res.stderr});
        std.process.exit(1);
    }
    allocator.free(res.stderr);
    const config_section = res.stdout[std.mem.find(u8, res.stdout, "\nCONFIGURATION FILE\n").?..];
    const variables_section = config_section[std.mem.find(u8, config_section, "\n   Variables\n").?..];
    return variables_section[0..std.mem.find(u8, variables_section, "\nBUGS\n").?];
}

fn handleOpenDoc(p: Lsp.OpenDocumentParameters) void {
    const configs = createConfigMap(p.gpa, p.io) catch unreachable;
    const config_text = getConfigText(p.gpa, p.io) catch unreachable;
    p.context.state = State.init(config_text, configs);
    p.context.document.init_ts(tree_sitter_git_config()) catch unreachable;
    sendDiagnostics(p.arena.allocator(), p.context.server, &p.context.state.?, p.context.document);
}

fn handleCloseDoc(p: Lsp.CloseDocumentParameters) void {
    const state = p.context.state orelse return;
    state.deinit();
}

fn posToPoint(p: lsp.types.Position) ts.Point {
    return .{ .row = @intCast(p.line), .column = @intCast(p.character) };
}
fn handleChange(p: Lsp.ChangeDocumentParameters) void {
    const allocator = p.arena.allocator();
    sendDiagnostics(allocator, p.context.server, &p.context.state.?, p.context.document);
}

fn handleSave(p: Lsp.SaveDocumentParameters) void {
    _ = p;
    // var state: State = p.context.state orelse return;
    // sendDiagnostics(p.allocator, p.context.server, &state, p.context.document);
}

fn sendDiagnostics(allocator: std.mem.Allocator, server: *Lsp, state: *State, doc: Lsp.Document) void {
    var diagnostics = std.ArrayList(lsp.types.Diagnostic).empty;

    var cursor = doc.tree.?.walk();
    const errors = lint.lint(allocator, state.configs, doc.doc.text, &cursor) catch unreachable;

    for (errors.items) |e| {
        diagnostics.append(allocator, .{
            .message = e.message(),
            .range = .{
                .start = e.start,
                .end = e.end,
            },
            .severity = .Error,
            .source = "git-ls",
        }) catch unreachable;
    }

    const d = lsp.types.Notification.PublishDiagnostics{ .params = .{
        .uri = doc.doc.uri,
        .diagnostics = diagnostics.items,
    } };
    server.writeResponse(allocator, d) catch unreachable;
}

fn addText(allocator: std.mem.Allocator, text: *std.ArrayList(u8), new: []const u8) void {
    text.appendSlice(allocator, new) catch unreachable;
}
fn nextNode(cursor: *ts.TreeCursor, skip_children: bool) ?ts.Node {
    if (!skip_children and cursor.gotoFirstChild()) return cursor.node();
    if (cursor.gotoNextSibling()) return cursor.node();
    while (cursor.gotoParent()) {
        if (cursor.gotoNextSibling()) return cursor.node();
    }
    return null;
}
fn handleFormat(p: Lsp.FormattingParameters) Lsp.FormattingReturn {
    const allocator = p.arena.allocator();
    const doc = p.context.document;
    var cursor = doc.tree.?.walk();
    var new_text = std.ArrayList(u8).initCapacity(allocator, p.context.document.doc.text.len) catch unreachable;

    var skip_children = false;
    while (nextNode(&cursor, skip_children)) |node| {
        skip_children = false;
        if (std.mem.eql(u8, node.kind(), "section")) {
            const prev = node.prevSibling() orelse continue;
            if (prev.childCount() == 0) continue;
            if (std.mem.eql(u8, prev.child(prev.childCount() - 1).?.kind(), "comment")) continue;
            if (std.mem.eql(u8, (node.prevSibling() orelse continue).kind(), "section"))
                addText(allocator, &new_text, "\n");
        }
        if (std.mem.eql(u8, node.kind(), "[")) addText(allocator, &new_text, "[");
        if (std.mem.eql(u8, node.kind(), "section_name")) {
            addText(allocator, &new_text, doc.nodeText(node));
            if (std.mem.eql(u8, (node.nextSibling() orelse continue).kind(), "\"")) addText(allocator, &new_text, " ");
        }
        if (std.mem.eql(u8, node.kind(), "\"")) addText(allocator, &new_text, "\"");
        if (std.mem.eql(u8, node.kind(), "subsection_name")) addText(allocator, &new_text, doc.nodeText(node));
        if (std.mem.eql(u8, node.kind(), "]")) {
            addText(allocator, &new_text, "]");
            if (node.nextSibling() == null or !std.mem.eql(u8, node.nextSibling().?.kind(), "comment"))
                addText(allocator, &new_text, "\n");
        }
        if (std.mem.eql(u8, node.kind(), "variable")) addText(allocator, &new_text, "    ");
        if (std.mem.eql(u8, node.kind(), "name")) addText(allocator, &new_text, doc.nodeText(node));
        if (std.mem.eql(u8, node.kind(), "=")) {
            addText(allocator, &new_text, " = ");
        }
        if (std.mem.eql(u8, node.kind(), "string") or
            std.mem.eql(u8, node.kind(), "integer") or
            std.mem.eql(u8, node.kind(), "true") or
            std.mem.eql(u8, node.kind(), "false"))
        {
            skip_children = true;
            addText(allocator, &new_text, doc.nodeText(node));
            if (node.nextSibling() == null or !std.mem.eql(u8, node.nextSibling().?.kind(), "comment"))
                addText(allocator, &new_text, "\n");
        }
        if (std.mem.eql(u8, node.kind(), "comment")) {
            if (node.nextSibling() == null and node.parent().?.nextSibling() != null) {
                addText(allocator, &new_text, "\n");
            } else if (node.prevSibling() != null) {
                addText(allocator, &new_text, "    ");
            }
            addText(allocator, &new_text, doc.nodeText(node));
            addText(allocator, &new_text, "\n");
        }
    }

    const edits = doc.doc.transform(allocator, new_text.items) catch unreachable;
    return edits.items;
}

fn countLeadingSpaces(config_text: []const u8, start: usize) usize {
    const line_start = std.mem.findLast(u8, config_text[0..start], "\n").? + 1;
    return config_text[line_start..start].len - std.mem.trim(u8, config_text[line_start..start], " ").len;
}
fn lookupDocumentation(config_text: []const u8, section_name: []const u8, subsection_name: ?[]const u8, name: ?[]const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    const section = std.fmt.bufPrint(&buf, "   {s}{s}{s}{s}{s}\n", .{
        section_name,
        if (subsection_name) |_| "." else "",
        if (subsection_name) |s| s else "",
        if (name) |_| "." else "",
        if (name) |n| n else "",
    }) catch unreachable;
    if (std.mem.find(u8, config_text, section)) |start| {
        const leading_spaces = countLeadingSpaces(config_text, start + 3);
        var lines = std.mem.splitScalar(u8, config_text[start..], '\n');
        const start_line = lines.next().?;
        var end = start + start_line.len;
        while (lines.next()) |l| {
            if (l.len == 0) {
                end += 1;
            } else if (countLeadingSpaces(config_text, end + l.len) > leading_spaces) {
                end += l.len + 1;
            } else break;
        }
        return config_text[std.mem.findScalarLast(u8, config_text[0..start], '\n').?..end];
    }
    return null;
}
fn handleHover(p: Lsp.HoverParameters) Lsp.HoverReturn {
    const state: State = p.context.state.?;
    const root = p.context.document.tree.?.rootNode();

    const content = p.context.document.doc.text;

    const point: ts.Point = .{ .row = @intCast(p.position.line), .column = @intCast(p.position.character) };
    const node = root.namedDescendantForPointRange(point, point) orelse return null;

    if (std.mem.eql(u8, node.kind(), "section_name")) {
        return lookupDocumentation(state.config_text, content[node.startByte()..node.endByte()], null, null);
    }
    if (std.mem.eql(u8, node.kind(), "subsection_name")) {
        const section_node = node.prevNamedSibling().?;
        std.debug.assert(std.mem.eql(u8, section_node.kind(), "section_name"));
        return lookupDocumentation(state.config_text, content[section_node.startByte()..section_node.endByte()], content[node.startByte()..node.endByte()], null);
    }
    if (std.mem.eql(u8, node.kind(), "name")) {
        var section_header = node.parent().?.prevSibling().?;
        while (!std.mem.eql(u8, section_header.kind(), "section_header")) {
            section_header = section_header.prevNamedSibling().?;
        }
        const section = section_header.namedChild(0).?;
        const section_name = content[section.startByte()..section.endByte()];
        const subsection_name = if (section.nextNamedSibling()) |s| content[s.startByte()..s.endByte()] else null;
        return lookupDocumentation(state.config_text, section_name, subsection_name, content[node.startByte()..node.endByte()]);
    }
    return null;
}
