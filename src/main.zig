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
    const configs = try createConfigMap(init.arena.allocator(), init.io);
    var keys = configs.keyIterator();
    while (keys.next()) |k| {
        std.debug.print("{s}\n", .{k.*});
    }
    return 0;
}
