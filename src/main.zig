const std = @import("std");

const ts = @import("tree-sitter");
const lsp = @import("lsp");

const lint = @import("lint.zig");

const State = struct {
    configs: ConfigMap,
    language: *ts.Language,
    parser: *ts.Parser,
    tree: *ts.Tree,

    const Self = @This();
    fn init(configs: ConfigMap, content: []const u8) Self {
        const language = tree_sitter_git_config();
        const parser = ts.Parser.create();
        parser.setLanguage(language) catch unreachable;
        const tree = parser.parseString(content, null) orelse unreachable;
        return State{
            .configs = configs,
            .language = language,
            .parser = parser,
            .tree = tree,
        };
    }

    fn parse(self: *Self, content: []const u8) void {
        self.tree = self.parser.parseString(content, null) orelse unreachable;
    }

    fn deinit(self: Self) void {
        self.tree.destroy();
        const language = self.parser.getLanguage().?;
        self.parser.destroy();
        language.destroy();
    }
};
const Lsp = lsp.Lsp(.{ .state_type = State, .update_doc_on_change = false });

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
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const server_info = lsp.types.ServerInfo{
        .name = "git-config-ls",
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
    p.server.registerCallbacks(comptime &[_]Lsp.Callback{
        .{ .OpenDocument = handleOpenDoc },
        .{ .ChangeDocument = handleChange },
        .{ .SaveDocument = handleSave },
        .{ .CloseDocument = handleCloseDoc },
    });
}

fn handleOpenDoc(p: Lsp.OpenDocumentParameters) void {
    const configs = createConfigMap(p.gpa, p.io) catch unreachable;
    p.context.state = State.init(configs, p.context.document.text);
    sendDiagnostics(p.allocator, p.context.server, &p.context.state.?, p.context.document);
}

fn handleCloseDoc(p: Lsp.CloseDocumentParameters) void {
    const state = p.context.state orelse return;
    state.deinit();
}

fn posToPoint(p: lsp.types.Position) ts.Point {
    return .{ .row = @intCast(p.line), .column = @intCast(p.character) };
}
fn handleChange(p: Lsp.ChangeDocumentParameters) void {
    var doc: *lsp.Document = &p.context.document;
    var tree: *ts.Tree = p.context.state.?.tree;
    var parser: *ts.Parser = p.context.state.?.parser;
    for (p.changes) |c| {
        var edit = ts.InputEdit{
            .start_byte = @intCast(doc.posToIdx(c.range.?.start).?),
            .old_end_byte = @intCast(doc.posToIdx(c.range.?.end).?),
            .start_point = posToPoint(c.range.?.start),
            .old_end_point = posToPoint(c.range.?.end),
            .new_end_byte = 0,
            .new_end_point = .{ .row = 0, .column = 0 },
        };
        doc.update(c) catch unreachable;
        edit.new_end_byte = @intCast(edit.start_byte + c.text.len);
        edit.new_end_point = posToPoint(doc.idxToPos(edit.new_end_byte).?);

        tree.edit(edit);
        tree = parser.parseString(doc.text, tree).?;
        p.context.state.?.tree = tree;
    }
    sendDiagnostics(p.allocator, p.context.server, &p.context.state.?, p.context.document);
}

fn handleSave(p: Lsp.SaveDocumentParameters) void {
    _ = p;
    // var state: State = p.context.state orelse return;
    // sendDiagnostics(p.allocator, p.context.server, &state, p.context.document);
}

fn sendDiagnostics(allocator: std.mem.Allocator, server: *Lsp, state: *State, doc: lsp.Document) void {
    var diagnostics = std.ArrayList(lsp.types.Diagnostic).empty;

    var cursor = state.tree.walk();
    const errors = lint.lint(allocator, state.configs, doc.text, &cursor) catch unreachable;

    for (errors.items) |e| {
        diagnostics.append(allocator, .{
            .message = e.message(),
            .range = .{
                .start = e.start,
                .end = e.end,
            },
            .severity = .Error,
            .source = "git-config-ls",
        }) catch unreachable;
    }

    const d = lsp.types.Notification.PublishDiagnostics{ .params = .{
        .uri = doc.uri,
        .diagnostics = diagnostics.items,
    } };
    server.writeResponse(allocator, d) catch unreachable;
}
