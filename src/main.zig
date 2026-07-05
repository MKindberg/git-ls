const std = @import("std");
const ts = @import("tree-sitter");
const lint = @import("lint.zig");

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

pub fn main(init: std.process.Init) !u8 {
    const language = tree_sitter_git_config();
    defer language.destroy();

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(language);

    const configs = try createConfigMap(init.arena.allocator(), init.io);

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const command = args.next() orelse return 1;
    const file = args.next() orelse return 1;
    const content = try std.Io.Dir.cwd().readFileAlloc(init.io, file, init.gpa, .unlimited);
    defer init.gpa.free(content);

    const tree = parser.parseString(content, null);
    defer tree.?.destroy();
    var cursor = tree.?.walk();
    if (std.mem.eql(u8, command, "lint")) {
        var errors = try lint.lint(init.gpa, configs, file, content, &cursor);
        defer errors.deinit(init.gpa);
        for (errors.items) |e| {
            std.debug.print("{s}:{} {s}\n", .{ e.filename, e.line, e.message() });
        }
    }

    return 0;
}
