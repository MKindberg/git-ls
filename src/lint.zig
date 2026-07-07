const std = @import("std");

const ts = @import("tree-sitter");
const lsp = @import("lsp");

const ConfigMap = @import("main.zig").ConfigMap;

const Err = struct {
    start: lsp.types.Position,
    end: lsp.types.Position,
    _buf: [100]u8 = undefined,
    _message_len: usize = undefined,

    const Self = @This();
    fn init(line: usize, char_start: usize, char_end: usize, comptime fmt: []const u8, args: anytype) Self {
        var err = Err{ .start = .{ .line = line, .character = char_start }, .end = .{ .line = line, .character = char_end } };
        err._message_len = (std.fmt.bufPrint(&err._buf, fmt, args) catch @as([]u8, &err._buf)).len;
        return err;
    }

    pub fn message(self: *const Self) []const u8 {
        return self._buf[0..self._message_len];
    }
};

fn hasOption(configs: ConfigMap, section: []const u8, subsection: ?[]const u8, name: ?[]const u8) bool {
    var buf: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    var l1_keys = configs.keyIterator();
    const l2 = l2: while (l1_keys.next()) |k| {
        if (std.mem.eql(u8, std.ascii.lowerString(&buf, section), std.ascii.lowerString(&buf2, k.*))) break :l2 configs.get(k.*).?;
    } else return false;

    if (subsection == null and name == null) return true;
    var l2_keys = l2.keyIterator();
    while (l2_keys.next()) |k| {
        if (std.mem.eql(u8, std.ascii.lowerString(&buf, subsection orelse name.?), std.ascii.lowerString(&buf2, k.*)) or k.*[0] == '<' or k.*[0] == '*') {
            if (subsection == null or name == null) return true;
            const l3 = l2.get(k.*).?;
            var l3_keys = l3.keyIterator();
            while (l3_keys.next()) |kk| {
                if (std.mem.eql(u8, std.ascii.lowerString(&buf, name.?), std.ascii.lowerString(&buf, kk.*)) or kk.*[0] == '<' or k.*[0] == '*') return true;
            }
        }
    }
    return false;
}

fn nextNode(cursor: *ts.TreeCursor, skip_children: bool) bool {
    if (!skip_children and cursor.gotoFirstChild()) return true;
    if (cursor.gotoNextSibling()) return true;
    while (cursor.gotoParent()) {
        if (cursor.gotoNextSibling()) return true;
    }
    return false;
}

fn skipSection(cursor: *ts.TreeCursor) void {
    while (!std.mem.eql(u8, cursor.node().kind(), "section")) _ = cursor.gotoParent();
}

pub fn lint(allocator: std.mem.Allocator, configs: ConfigMap, content: []const u8, cursor: *ts.TreeCursor) !std.ArrayList(Err) {
    var errors = std.ArrayList(Err).empty;
    errdefer errors.deinit(allocator);

    if (cursor.node().isError()) {
        try errors.append(allocator, Err.init(1, 1, 1, "Failed to parse config", .{}));
        return errors;
    }

    var section_name: ?[]const u8 = null;
    var subsection_name: ?[]const u8 = null;
    var skip_children = false;
    while (nextNode(cursor, skip_children)) {
        skip_children = false;
        const node = cursor.node();
        if (node.isError()) {
            try errors.append(allocator, Err.init(
                node.startPoint().row,
                node.startPoint().column,
                node.endPoint().column,
                "Invalid {s}: '{s}",
                .{ node.child(0).?.kind(), content[node.startByte()..node.endByte()] },
            ));
            skip_children = true;
            continue;
        }
        if (node.isMissing()) {
            const parent = node.parent().?;
            const parent_expr = content[parent.startByte()..parent.endByte()];
            try errors.append(allocator, Err.init(
                node.startPoint().row,
                node.startPoint().column,
                node.endPoint().column,
                "Missing '{s}' in '{s}'",
                .{ node.kind(), parent_expr },
            ));
        }
        if (std.mem.eql(u8, node.kind(), "section_name")) {
            section_name = content[node.startByte()..node.endByte()];
            subsection_name = null;
            if (!hasOption(configs, section_name.?, null, null)) {
                try errors.append(allocator, Err.init(
                    node.startPoint().row,
                    node.startPoint().column,
                    node.endPoint().column,
                    "Invalid section '{s}'",
                    .{section_name.?},
                ));
                skipSection(cursor);
                skip_children = true;
            }
        } else if (std.mem.eql(u8, node.kind(), "subsection_name")) {
            subsection_name = content[node.startByte()..node.endByte()];
            if (!hasOption(configs, section_name.?, subsection_name.?, null)) {
                try errors.append(allocator, Err.init(
                    node.startPoint().row,
                    node.startPoint().column,
                    node.endPoint().column,
                    "Invalid subsection '{s}.{s}'",
                    .{ section_name.?, subsection_name.? },
                ));
                skipSection(cursor);
                skip_children = true;
            }
        } else if (std.mem.eql(u8, node.kind(), "name")) {
            const name = content[node.startByte()..node.endByte()];
            if (!hasOption(configs, section_name.?, subsection_name, name)) {
                try errors.append(allocator, Err.init(
                    node.startPoint().row,
                    node.startPoint().column,
                    node.endPoint().column,
                    "Invalid option '{s}{s}{s}.{s}'",
                    .{
                        section_name.?,
                        if (subsection_name != null) "." else "",
                        subsection_name orelse "",
                        name,
                    },
                ));
            }
        }
    }

    return errors;
}
