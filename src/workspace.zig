const std = @import("std");
const exec = @import("exec.zig");
const model = @import("model.zig");

pub const ResolvedWorkspace = struct {
    local_root: []u8,
    current_dir: []u8,
    remote_root: []u8,
    name: []u8,

    pub fn deinit(self: ResolvedWorkspace, allocator: std.mem.Allocator) void {
        allocator.free(self.local_root);
        allocator.free(self.current_dir);
        allocator.free(self.remote_root);
        allocator.free(self.name);
    }
};

pub fn discover(
    allocator: std.mem.Allocator,
    existing: ?model.WorkspaceRecord,
) !ResolvedWorkspace {
    const current_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(current_dir);

    const local_root = try detectRepoRoot(allocator, current_dir);
    errdefer allocator.free(local_root);

    const name = try workspaceName(allocator, local_root);
    errdefer allocator.free(name);

    const remote_root = if (existing) |workspace_record|
        if (std.mem.eql(u8, workspace_record.local_path, local_root))
            try allocator.dupe(u8, workspace_record.remote_path)
        else
            try std.fmt.allocPrint(allocator, "$HOME/work/{s}", .{name})
    else
        try std.fmt.allocPrint(allocator, "$HOME/work/{s}", .{name});
    errdefer allocator.free(remote_root);

    return .{
        .local_root = local_root,
        .current_dir = current_dir,
        .remote_root = remote_root,
        .name = name,
    };
}

pub fn mapLocalPath(
    allocator: std.mem.Allocator,
    resolved: ResolvedWorkspace,
    local_path: []const u8,
) ![]u8 {
    if (!isWithinRoot(resolved.local_root, local_path)) {
        return allocator.dupe(u8, resolved.remote_root);
    }

    if (local_path.len == resolved.local_root.len) {
        return allocator.dupe(u8, resolved.remote_root);
    }

    const suffix = local_path[resolved.local_root.len..];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ resolved.remote_root, suffix });
}

pub fn quoteRemotePath(
    allocator: std.mem.Allocator,
    remote_path: []const u8,
) ![]u8 {
    if (!std.mem.startsWith(u8, remote_path, "$HOME")) {
        return quoteDouble(allocator, remote_path);
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll("\"$HOME");
    for (remote_path["$HOME".len..]) |char| {
        switch (char) {
            '"', '\\', '$', '`' => {
                try writer.writer.writeByte('\\');
                try writer.writer.writeByte(char);
            },
            else => try writer.writer.writeByte(char),
        }
    }
    try writer.writer.writeByte('"');

    return allocator.dupe(u8, writer.written());
}

fn detectRepoRoot(
    allocator: std.mem.Allocator,
    current_dir: []const u8,
) ![]u8 {
    const result = exec.run(allocator, &.{
        "git",
        "-C",
        current_dir,
        "rev-parse",
        "--show-toplevel",
    }) catch {
        return allocator.dupe(u8, current_dir);
    };
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        return allocator.dupe(u8, current_dir);
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, "\r\n");
    if (trimmed.len == 0) {
        return allocator.dupe(u8, current_dir);
    }

    return allocator.dupe(u8, trimmed);
}

fn workspaceName(
    allocator: std.mem.Allocator,
    local_root: []const u8,
) ![]u8 {
    const base = std.fs.path.basename(local_root);
    if (base.len == 0) {
        return allocator.dupe(u8, "workspace");
    }

    return allocator.dupe(u8, base);
}

fn isWithinRoot(
    root: []const u8,
    path: []const u8,
) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    if (root.len == 0) return false;

    const next = path[root.len];
    return next == std.fs.path.sep;
}

fn quoteDouble(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeByte('"');
    for (raw) |char| {
        switch (char) {
            '"', '\\', '$', '`' => {
                try writer.writer.writeByte('\\');
                try writer.writer.writeByte(char);
            },
            else => try writer.writer.writeByte(char),
        }
    }
    try writer.writer.writeByte('"');

    return allocator.dupe(u8, writer.written());
}

test "map local path inside repo to remote workspace" {
    const allocator = std.testing.allocator;
    const resolved = ResolvedWorkspace{
        .local_root = try allocator.dupe(u8, "/tmp/project"),
        .current_dir = try allocator.dupe(u8, "/tmp/project/src"),
        .remote_root = try allocator.dupe(u8, "$HOME/work/project"),
        .name = try allocator.dupe(u8, "project"),
    };
    defer resolved.deinit(allocator);

    const mapped = try mapLocalPath(allocator, resolved, "/tmp/project/src");
    defer allocator.free(mapped);

    try std.testing.expectEqualStrings("$HOME/work/project/src", mapped);
}

test "quote remote HOME path keeps expansion" {
    const allocator = std.testing.allocator;
    const quoted = try quoteRemotePath(allocator, "$HOME/work/project/src");
    defer allocator.free(quoted);

    try std.testing.expectEqualStrings("\"$HOME/work/project/src\"", quoted);
}
