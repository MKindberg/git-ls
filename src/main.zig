const std = @import("std");
const Io = std.Io;

const SubSubConfigMap = std.StringHashMap(void);
const SubConfigMap = std.StringHashMap(SubSubConfigMap);
const ConfigMap = std.StringHashMap(SubConfigMap);

fn createConfigMap(allocator: std.mem.Allocator, io: std.Io) !ConfigMap {
    var configs = ConfigMap.init(allocator);

    const git_result = try std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "git", "help", "--config" } });
    if (git_result.term != .exited or git_result.term.exited != 0) {
        std.debug.print("Failed to get manual for git-config: {s}\n", .{git_result.stderr});
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

fn err(file: []const u8, line: usize, comptime message: []const u8, args: anytype) noreturn {
    std.debug.print("{s}:{} " ++ message ++ "\n", .{ file, line } ++ args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !u8 {
    const configs = try createConfigMap(init.arena.allocator(), init.io);

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const command = args.next() orelse return 1;
    const file = args.next() orelse return 1;
    const content = try std.Io.Dir.cwd().readFileAlloc(init.io, file, init.gpa, .unlimited);
    defer init.gpa.free(content);

    if (std.mem.eql(u8, command, "lint")) {
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
                const section_end = std.mem.findAnyPos(u8, line, c, ". ]") orelse err(file, l, "Missing end bracket", .{});
                level1 = line[section_start..section_end];
                if (!hasConfig(configs, level1.?, null, null)) err(file, l, "Invalid section {s}", .{level1.?});
                c = section_end;
                while (c < line.len and std.ascii.isWhitespace(line[c])) c += 1;
                if (line[c] == '.') {
                    const subsection_start = c + 1;
                    const subsection_end = std.mem.findAnyPos(u8, line, c, " ]") orelse err(file, l, "Missing end bracket", .{});
                    level2 = line[subsection_start..subsection_end];
                    if (!hasConfig(configs, level1.?, level2.?, null)) err(file, l, "Invalid subsection {s}", .{level2.?});
                    c = subsection_end;
                }
                if (line[c] == '"') {
                    c += 1;
                    const subsection_start = c;
                    const subsection_end = std.mem.findScalarPos(u8, line, c, '"') orelse err(file, l, "Missing end quote", .{});
                    level2 = line[subsection_start..subsection_end];
                    if (!hasConfig(configs, level1.?, level2.?, null)) err(file, l, "Invalid subsection {s}", .{level2.?});
                    c = subsection_end + 1;
                }
                while (c < line.len and std.ascii.isWhitespace(line[c])) c += 1;
                if (line[c] != ']') err(file, l, "Missing end bracket", .{});
                c += 1;
                while (c < line.len and std.ascii.isWhitespace(line[c])) c += 1;
                if (c != line.len and c != '#') err(file, l, "Text after bracket no allowed", .{});
                continue;
            } else {
                if (level1 == null) err(file, l, "Everything needs to be part of a section", .{});
                const option_start = c;
                const option_end = std.mem.findAnyPos(u8, line, c, "= ") orelse line.len;
                if (level2 == null) {
                    const key = line[option_start..option_end];
                    if (!hasConfig(configs, level1.?, key, null)) err(file, l, "Invalid key '{s}'", .{key});
                } else {
                    const key = line[option_start..option_end];
                    if (!hasConfig(configs, level1.?, level2.?, key)) err(file, l, "Invalid key '{s}'", .{key});
                }
            }
        }
    }

    return 0;
}
