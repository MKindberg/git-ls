const std = @import("std");
const ConfigMap = @import("main.zig").ConfigMap;
const Err = struct {
    filename: []const u8,
    line: usize,
    char_start: usize,
    char_end: usize,
    _buf: [100]u8 = undefined,
    _message_len: usize = undefined,

    const Self = @This();
    fn init(filename: []const u8, line: usize, char_start: usize, char_end: usize, comptime fmt: []const u8, args: anytype) Self {
        var err = Err{ .filename = filename, .line = line, .char_start = char_start, .char_end = char_end };
        err._message_len = (std.fmt.bufPrint(&err._buf, fmt, args) catch @as([]u8, &err._buf)).len;
        return err;
    }

    pub fn message(self: *const Self) []const u8 {
        return self._buf[0..self._message_len];
    }
};

fn hasConfig(configs: ConfigMap, level1: []const u8, level2: ?[]const u8, level3: ?[]const u8) bool {
    var buf: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    var l1_keys = configs.keyIterator();
    const l2 = l2: while (l1_keys.next()) |k| {
        if (std.mem.eql(u8, std.ascii.lowerString(&buf, level1), std.ascii.lowerString(&buf2, k.*))) break :l2 configs.get(k.*).?;
    } else return false;

    if (level2 == null) return true;
    var l2_keys = l2.keyIterator();
    while (l2_keys.next()) |k| {
        if (std.mem.eql(u8, std.ascii.lowerString(&buf, level2.?), std.ascii.lowerString(&buf2, k.*)) or k.*[0] == '<' or k.*[0] == '*') {
            if (level3 == null) return true;
            const l3 = l2.get(k.*).?;
            var l3_keys = l3.keyIterator();
            while (l3_keys.next()) |kk| {
                if (std.mem.eql(u8, std.ascii.lowerString(&buf, level3.?), std.ascii.lowerString(&buf, kk.*)) or kk.*[0] == '<' or k.*[0] == '*') return true;
            }
        }
    }
    return false;
}

pub fn lint(allocator: std.mem.Allocator, configs: ConfigMap, filename: []const u8, content: []const u8) !std.ArrayList(Err) {
    var errors = std.ArrayList(Err).empty;
    errdefer errors.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var level1: ?[]const u8 = null;
    var level2: ?[]const u8 = null;

    var l: usize = 1;
    while (lines.next()) |line| : (l += 1) {
        var c: usize = 0;
        while (c < line.len and std.ascii.isWhitespace(line[c])) c += 1;
        // Parse section
        if (c == line.len) continue;
        if (line[c] == '#' or line[c] == ';') continue;
        if (line[c] == '[') {
            level1 = null;
            level2 = null;
            const section_start = c + 1;
            const section_end = std.mem.findAnyPos(u8, line, c, ". ]") orelse {
                try errors.append(allocator, Err.init(filename, l, 0, line.len, "Missing end bracket", .{}));
                return errors;
            };
            level1 = line[section_start..section_end];
            if (!hasConfig(configs, level1.?, null, null)) {
                try errors.append(allocator, Err.init(filename, l, section_start, section_end, "Invalid section '{s}'", .{level1.?}));
                continue;
            }
            c = section_end;
            while (c < line.len and std.ascii.isWhitespace(line[c])) c += 1;
            if (line[c] == '.') {
                const subsection_start = c + 1;
                const subsection_end = std.mem.findAnyPos(u8, line, c, " ]") orelse {
                    try errors.append(allocator, Err.init(filename, l, 0, line.len, "Missing end bracket", .{}));
                    return errors;
                };
                level2 = line[subsection_start..subsection_end];
                if (!hasConfig(configs, level1.?, level2.?, null)) {
                    try errors.append(allocator, Err.init(filename, l, section_start, section_end, "Invalid subsection '{s}'", .{level2.?}));
                    continue;
                }
                c = subsection_end;
            }
            if (line[c] == '"') {
                c += 1;
                const subsection_start = c;
                const subsection_end = std.mem.findScalarPos(u8, line, c, '"') orelse {
                    try errors.append(allocator, Err.init(filename, l, 0, line.len, "Missing end quote", .{}));
                    return errors;
                };
                level2 = line[subsection_start..subsection_end];
                if (!hasConfig(configs, level1.?, level2.?, null)) {
                    try errors.append(allocator, Err.init(filename, l, section_start, section_end, "Invalid subsection '{s}'", .{level2.?}));
                    continue;
                }
                c = subsection_end + 1;
            }
            while (c < line.len and std.ascii.isWhitespace(line[c])) c += 1;
            if (line[c] != ']') {
                try errors.append(allocator, Err.init(filename, l, 0, line.len, "Missing end bracket", .{}));
                return errors;
            }
            c += 1;
            while (c < line.len and std.ascii.isWhitespace(line[c])) c += 1;
            if (c != line.len and c != '#') {
                try errors.append(allocator, Err.init(filename, l, c, line.len, "Text after bracket no allowed", .{}));
                continue;
            }
            continue;
        } else {
            if (level1 == null) {
                try errors.append(allocator, Err.init(filename, l, 0, line.len, "Line not part of any section", .{}));
                continue;
            }
            const option_start = c;
            const option_end = std.mem.findAnyPos(u8, line, c, "= ") orelse line.len;
            if (level2 == null) {
                const key = line[option_start..option_end];
                if (!hasConfig(configs, level1.?, key, null)) {
                    try errors.append(allocator, Err.init(filename, l, option_start, option_end, "Invalid key '{s}'", .{key}));
                    continue;
                }
            } else {
                const key = line[option_start..option_end];
                if (!hasConfig(configs, level1.?, level2.?, key)) {
                    try errors.append(allocator, Err.init(filename, l, option_start, option_end, "Invalid key '{s}'", .{key}));
                    continue;
                }
            }
        }
    }
    return errors;
}
