const std = @import("std");

const ts = @import("tree-sitter");
const lsp = @import("lsp");

const Lsp = lsp.Lsp(.{
    .state_type = State,
    .document_type = lsp.TreeSitterDocument,
    .config_options = &[_][]const u8{
        "newline_after_section",
        "sort_options",
        "sort_sections",
    },
});

const FormattingOptions = struct {
    tabSize: u32 = 4,
    insertSpaces: bool = true,

    newline_after_section: bool = true,
    sort_options: bool = false,
    sort_sections: bool = false,
};

const State = struct {
    config_text: []const u8,

    const Self = @This();
    fn init(config_text: []const u8) Self {
        return State{
            .config_text = config_text,
        };
    }

    fn deinit(self: Self) void {
        _ = self;
    }
};

var format_options: FormattingOptions = .{};

extern fn tree_sitter_git_config() callconv(.c) *ts.Language;

const SubSubConfigMap = std.StringHashMap(void);
const SubConfigMap = std.StringHashMap(SubSubConfigMap);
pub const ConfigMap = std.StringHashMap(SubConfigMap);

pub fn main(init: std.process.Init) !u8 {
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
    p.server.registerCallback(.{ .@"textDocument/didOpen" = handleOpenDoc });
    p.server.registerCallback(.{ .@"textDocument/didClose" = handleCloseDoc });
    p.server.registerCallback(.{ .@"textDocument/formatting" = handleFormat });
    p.server.registerCallback(.{ .@"textDocument/hover" = handleHover });
    p.server.registerCallback(.{ .@"workspace/didChangeConfiguration" = handleNewConfig });
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
    const config_text = getConfigText(p.context.server.allocator, p.context.server.io) catch unreachable;
    p.context.state = State.init(config_text);
    p.context.document.init_ts(tree_sitter_git_config()) catch unreachable;
}

fn handleCloseDoc(p: Lsp.CloseDocumentParameters) void {
    const state = p.context.state orelse return;
    state.deinit();
}

fn handleFormat(p: Lsp.FormattingParameters) Lsp.FormattingReturn {
    const allocator = p.arena.allocator();
    const doc: lsp.TreeSitterDocument = p.context.document;
    format_options.tabSize = p.params.options.tabSize;
    format_options.insertSpaces = p.params.options.insertSpaces;

    if (doc.tree.?.rootNode().hasError()) return null;

    const config = GitConfig.parse(allocator, doc, doc.tree.?.rootNode()) catch unreachable;
    var formatted = config.format(allocator, format_options, doc) catch unreachable;
    formatted.writer.flush() catch unreachable;
    const edits = doc.doc.transform(allocator, formatted.written()) catch unreachable;
    return edits.items;
}

fn handleNewConfig(p: Lsp.ConfigurationChangeParameters) Lsp.ConfigurationChangeReturn {
    if (p.result[0] == .bool) format_options.newline_after_section = p.result[0].bool;
    if (p.result[1] == .bool) format_options.sort_options = p.result[1].bool;
    if (p.result[2] == .bool) format_options.sort_sections = p.result[2].bool;
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

    const point: ts.Point = .{ .row = @intCast(p.params.position.line), .column = @intCast(p.params.position.character) };
    const node = root.namedDescendantForPointRange(point, point) orelse return null;

    if (std.mem.eql(u8, node.kind(), "section_name")) {
        return .{ .contents = lookupDocumentation(state.config_text, content[node.startByte()..node.endByte()], null, null) orelse return null };
    }
    if (std.mem.eql(u8, node.kind(), "subsection_name")) {
        const section_node = node.prevNamedSibling().?;
        std.debug.assert(std.mem.eql(u8, section_node.kind(), "section_name"));
        return .{
            .contents = lookupDocumentation(
                state.config_text,
                content[section_node.startByte()..section_node.endByte()],
                content[node.startByte()..node.endByte()],
                null,
            ) orelse return null,
        };
    }
    if (std.mem.eql(u8, node.kind(), "name")) {
        var section_header = node.parent().?.prevSibling().?;
        while (!std.mem.eql(u8, section_header.kind(), "section_header")) {
            section_header = section_header.prevNamedSibling().?;
        }
        const section = section_header.namedChild(0).?;
        const section_name = content[section.startByte()..section.endByte()];
        const subsection_name = if (section.nextNamedSibling()) |s| content[s.startByte()..s.endByte()] else null;
        return .{ .contents = lookupDocumentation(
            state.config_text,
            section_name,
            subsection_name,
            content[node.startByte()..node.endByte()],
        ) orelse return null };
    }
    return null;
}

const GitConfig = struct {
    comment: std.ArrayList(ts.Node) = std.ArrayList(ts.Node).empty,
    sections: std.ArrayList(Section) = std.ArrayList(Section).empty,

    const Self = @This();
    fn parse(allocator: std.mem.Allocator, doc: lsp.TreeSitterDocument, root: ts.Node) !Self {
        const content = doc.doc.text;
        var self = Self{};
        var node: ?ts.Node = root.namedChild(0);
        var section_comment = std.ArrayList(ts.Node).empty;
        defer section_comment.deinit(allocator);
        while (node) |n| {
            if (std.mem.eql(u8, n.kind(), "comment")) {
                try section_comment.append(allocator, n);

                if (n.endByte() < content.len - 2 and
                    content[n.endByte()] == '\n' and
                    content[n.endByte() + 1] == '\n')
                {
                    try self.comment.appendSlice(allocator, section_comment.items);
                    section_comment.clearRetainingCapacity();
                }
            } else if (std.mem.eql(u8, n.kind(), "section")) {
                try self.sections.append(allocator, try Section.parse(allocator, doc, &section_comment, n));
            } else unreachable;
            node = n.nextNamedSibling();
        }
        try self.comment.appendSlice(allocator, section_comment.items);
        if (format_options.sort_sections) {
            std.mem.sort(Section, self.sections.items, doc, Section.order);
        }
        return self;
    }
    fn format(self: Self, allocator: std.mem.Allocator, options: FormattingOptions, doc: lsp.TreeSitterDocument) !std.Io.Writer.Allocating {
        var formatted = try std.Io.Writer.Allocating.initCapacity(allocator, doc.doc.text.len);
        var writer = &formatted.writer;

        for (self.comment.items) |c| {
            try writer.writeAll(doc.nodeText(c));
            try writer.writeByte('\n');
        }
        if (self.comment.items.len != 0) try writer.writeByte('\n');

        for (self.sections.items) |s| {
            try s.format(doc, writer);
            if (options.newline_after_section) {
                try writer.writeByte('\n');
            }
        }

        return formatted;
    }
};

const Section = struct {
    comment: std.ArrayList(ts.Node),
    section: ts.Node,
    subsection: ?ts.Node,
    variables: std.ArrayList(Variable),

    const Self = @This();
    fn order(doc: lsp.TreeSitterDocument, a: Self, b: Self) bool {
        return std.ascii.orderIgnoreCase(doc.nodeText(a.section), doc.nodeText(b.section)) == .lt;
    }

    fn parse(allocator: std.mem.Allocator, doc: lsp.TreeSitterDocument, section_comment: *std.ArrayList(ts.Node), root: ts.Node) !Self {
        const content = doc.doc.text;
        var node: ?ts.Node = root.namedChild(0).?;
        var self: Self = .{
            .comment = try section_comment.clone(allocator),
            .section = node.?.namedChild(0).?,
            .subsection = node.?.namedChild(1),
            .variables = std.ArrayList(Variable).empty,
        };
        section_comment.clearRetainingCapacity();
        node = node.?.nextNamedSibling() orelse return self;
        while (node) |n| {
            if (std.mem.eql(u8, n.kind(), "comment")) {
                try section_comment.append(allocator, n);
                node = n.nextNamedSibling();
            } else if (std.mem.eql(u8, n.kind(), "variable")) {
                try self.variables.append(allocator, try Variable.parse(allocator, doc, section_comment.*, &node.?));
                section_comment.clearRetainingCapacity();
                node = node.?.nextNamedSibling();
            } else unreachable;
        }
        for (0..section_comment.items.len) |i| {
            const idx = section_comment.items.len - 1 - i;
            const n = section_comment.items[idx];
            if (n.endByte() > content.len - 2) {
                try self.variables.append(allocator, .{ .comment1 = try section_comment.clone(allocator) });
                section_comment.clearRetainingCapacity();
                break;
            }
            if (content[n.endByte()] == '\n' and content[n.endByte() + 1] == '\n') {
                var v: Variable = .{ .comment1 = try section_comment.clone(allocator) };
                section_comment.clearRetainingCapacity();
                section_comment.appendSliceAssumeCapacity(v.comment1.items[idx + 1 ..]);
                v.comment1.shrinkAndFree(allocator, idx + 1);
                try self.variables.append(allocator, v);
                break;
            }
        }

        if (format_options.sort_options) {
            std.mem.sort(Variable, self.variables.items, doc, Variable.order);
        }
        return self;
    }

    fn format(self: Self, doc: lsp.TreeSitterDocument, formatted: *std.Io.Writer) !void {
        for (self.comment.items) |c| {
            try formatted.writeAll(doc.nodeText(c));
            try formatted.writeByte('\n');
        }
        try formatted.writeByte('[');
        try formatted.writeAll(doc.nodeText(self.section));
        if (self.subsection) |s| {
            try formatted.writeByte(' ');
            try formatted.writeByte('"');
            try formatted.writeAll(doc.nodeText(s));
            try formatted.writeByte('"');
        }
        try formatted.writeByte(']');
        try formatted.writeByte('\n');

        for (self.variables.items) |v| {
            try v.format(doc, formatted);
        }
    }
};
const Variable = struct {
    comment1: std.ArrayList(ts.Node),
    name: ?ts.Node = null,
    value: ?ts.Node = null,
    comment2: ?ts.Node = null,

    const Self = @This();
    fn order(doc: lsp.TreeSitterDocument, a: Self, b: Self) bool {
        if (b.name == null) return false;
        if (a.name == null) return true;
        return std.ascii.orderIgnoreCase(doc.nodeText(a.name.?), doc.nodeText(b.name.?)) == .lt;
    }

    fn parse(allocator: std.mem.Allocator, doc: lsp.TreeSitterDocument, comment1: std.ArrayList(ts.Node), node: *ts.Node) !Self {
        const content = doc.doc.text;
        var self: Self = .{
            .comment1 = try comment1.clone(allocator),
            .name = node.namedChild(0),
            .value = node.namedChild(1),
        };
        const next = node.nextNamedSibling() orelse return self;
        if (std.mem.eql(u8, next.kind(), "comment") and std.mem.findScalar(u8, content[node.endByte()..next.startByte()], '\n') == null) {
            self.comment2 = next;
            node.* = next;
        }
        return self;
    }

    fn writeIndent(formatted: *std.Io.Writer) !void {
        if (format_options.insertSpaces) {
            try formatted.splatByteAll(' ', format_options.tabSize);
        } else {
            try formatted.writeByte('\t');
        }
    }
    fn format(self: Self, doc: lsp.TreeSitterDocument, formatted: *std.Io.Writer) !void {
        for (self.comment1.items) |c| {
            try writeIndent(formatted);
            try formatted.writeAll(doc.nodeText(c));
            try formatted.writeByte('\n');
        }
        if (self.name == null) return;

        try writeIndent(formatted);
        try formatted.writeAll(doc.nodeText(self.name.?));
        if (self.value) |v| {
            try formatted.writeByte(' ');
            try formatted.writeByte('=');
            try formatted.writeByte(' ');
            try formatted.writeAll(doc.nodeText(v));
        }
        if (self.comment2) |c| {
            try formatted.writeByte(' ');
            try formatted.writeAll(doc.nodeText(c));
        }
        try formatted.writeByte('\n');
    }
};
