const std = @import("std");
const exec = @import("exec.zig");
const model = @import("model.zig");

pub const bootstrap_hook_path = ".rove/bootstrap.sh";

pub const Error = error{
    AmbiguousWorkspaceSelector,
    NoTrackedWorkspace,
    WorkspaceNotFound,
};

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

pub const OwnedTrackedWorkspaces = struct {
    active: model.WorkspaceRecord,
    records: []model.WorkspaceRecord,

    pub fn deinit(self: OwnedTrackedWorkspaces, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
    }
};

const CurrentContext = struct {
    current_dir: []u8,
    local_root: []u8,
    name: []u8,

    fn deinit(self: CurrentContext, allocator: std.mem.Allocator) void {
        allocator.free(self.current_dir);
        allocator.free(self.local_root);
        allocator.free(self.name);
    }
};

pub fn discover(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !ResolvedWorkspace {
    var current = try currentContext(allocator);
    errdefer current.deinit(allocator);

    const tracked = findTrackedByLocalPath(machine, current.local_root);
    const remote_root = if (tracked) |record|
        try allocator.dupe(u8, record.remote_path)
    else
        try defaultRemoteRoot(allocator, machine, current.name, current.local_root);
    errdefer allocator.free(remote_root);

    return .{
        .local_root = current.local_root,
        .current_dir = current.current_dir,
        .remote_root = remote_root,
        .name = current.name,
    };
}

pub fn resolvePull(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    selector: ?[]const u8,
) !ResolvedWorkspace {
    if (selector) |value| {
        return fromRecord(allocator, try resolveTrackedSelector(machine, value));
    }

    var current = try currentContext(allocator);
    defer current.deinit(allocator);

    if (findTrackedByLocalPath(machine, current.local_root)) |tracked| {
        return fromRecord(allocator, tracked);
    }

    if (activeTracked(machine)) |tracked| {
        return fromRecord(allocator, tracked);
    }

    return error.NoTrackedWorkspace;
}

pub fn resolveTrackedSelector(
    machine: model.MachineRecord,
    selector: []const u8,
) Error!model.WorkspaceRecord {
    if (std.mem.eql(u8, selector, "active")) {
        return activeTracked(machine) orelse error.NoTrackedWorkspace;
    }

    if (parseSelectorIndex(selector)) |index| {
        return trackedByIndex(machine, index) orelse error.WorkspaceNotFound;
    }

    var found: ?model.WorkspaceRecord = null;

    if (machine.workspaces.len > 0) {
        for (machine.workspaces) |record| {
            if (!matchesSelector(record, selector)) continue;
            if (found != null) return error.AmbiguousWorkspaceSelector;
            found = record;
        }
    } else if (machine.workspace) |record| {
        if (matchesSelector(record, selector)) {
            found = record;
        }
    }

    return found orelse error.WorkspaceNotFound;
}

pub fn fromRecord(
    allocator: std.mem.Allocator,
    existing: model.WorkspaceRecord,
) !ResolvedWorkspace {
    const local_root = try allocator.dupe(u8, existing.local_path);
    errdefer allocator.free(local_root);

    const current_dir = try allocator.dupe(u8, existing.local_path);
    errdefer allocator.free(current_dir);

    const remote_root = try allocator.dupe(u8, existing.remote_path);
    errdefer allocator.free(remote_root);

    const name = try allocator.dupe(u8, recordName(existing));
    errdefer allocator.free(name);

    return .{
        .local_root = local_root,
        .current_dir = current_dir,
        .remote_root = remote_root,
        .name = name,
    };
}

pub fn buildRecord(
    resolved: ResolvedWorkspace,
    tmux_session: ?[]const u8,
) model.WorkspaceRecord {
    return .{
        .name = resolved.name,
        .local_path = resolved.local_root,
        .remote_path = resolved.remote_root,
        .tmux_session = tmux_session,
    };
}

pub fn mergeTracked(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    incoming: model.WorkspaceRecord,
) !OwnedTrackedWorkspaces {
    var records = std.ArrayListUnmanaged(model.WorkspaceRecord){};
    errdefer records.deinit(allocator);

    if (machine.workspaces.len > 0) {
        try records.appendSlice(allocator, machine.workspaces);
    }

    if (machine.workspace) |active| {
        upsertRecord(allocator, &records, active);
    }

    upsertRecord(allocator, &records, incoming);

    return .{
        .active = resolvedRecord(records.items, incoming.local_path).?,
        .records = try records.toOwnedSlice(allocator),
    };
}

pub fn activeTracked(machine: model.MachineRecord) ?model.WorkspaceRecord {
    if (machine.workspace) |record| return record;
    if (machine.workspaces.len > 0) return machine.workspaces[0];
    return null;
}

pub fn findTrackedByLocalPath(
    machine: model.MachineRecord,
    local_root: []const u8,
) ?model.WorkspaceRecord {
    if (machine.workspace) |record| {
        if (std.mem.eql(u8, record.local_path, local_root)) return record;
    }

    for (machine.workspaces) |record| {
        if (std.mem.eql(u8, record.local_path, local_root)) return record;
    }

    return null;
}

pub fn trackedCount(machine: model.MachineRecord) usize {
    if (machine.workspaces.len > 0) return machine.workspaces.len;
    if (machine.workspace != null) return 1;
    return 0;
}

pub fn recordName(record: model.WorkspaceRecord) []const u8 {
    if (record.name) |name| {
        if (name.len > 0) return name;
    }

    const base = std.fs.path.basename(record.local_path);
    if (base.len > 0) return base;

    return std.fs.path.basename(record.remote_path);
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

pub fn localBootstrapHookPath(
    allocator: std.mem.Allocator,
    resolved: ResolvedWorkspace,
) !?[]u8 {
    const hook_path = try std.fs.path.join(allocator, &.{ resolved.local_root, bootstrap_hook_path });
    errdefer allocator.free(hook_path);

    std.fs.cwd().access(hook_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(hook_path);
            return null;
        },
        else => return err,
    };

    return hook_path;
}

pub fn localRepoHasUncommittedChanges(
    allocator: std.mem.Allocator,
    local_root: []const u8,
) !bool {
    const result = exec.run(allocator, &.{
        "git",
        "-C",
        local_root,
        "status",
        "--porcelain",
    }) catch {
        return false;
    };
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        return false;
    }

    return std.mem.trim(u8, result.stdout, "\r\n\t ").len > 0;
}

fn currentContext(
    allocator: std.mem.Allocator,
) !CurrentContext {
    const current_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(current_dir);

    const local_root = try detectRepoRoot(allocator, current_dir);
    errdefer allocator.free(local_root);

    const name = try workspaceName(allocator, local_root);
    errdefer allocator.free(name);

    return .{
        .current_dir = current_dir,
        .local_root = local_root,
        .name = name,
    };
}

fn defaultRemoteRoot(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    name: []const u8,
    local_root: []const u8,
) ![]u8 {
    const base = try std.fmt.allocPrint(allocator, "$HOME/work/{s}", .{name});
    errdefer allocator.free(base);

    if (!remotePathInUse(machine, base, local_root)) {
        return base;
    }

    allocator.free(base);
    const suffix: u32 = @truncate(std.hash.Wyhash.hash(0, local_root));
    return std.fmt.allocPrint(allocator, "$HOME/work/{s}-{x}", .{ name, suffix });
}

fn remotePathInUse(
    machine: model.MachineRecord,
    candidate: []const u8,
    local_root: []const u8,
) bool {
    if (machine.workspace) |record| {
        if (std.mem.eql(u8, record.remote_path, candidate) and !std.mem.eql(u8, record.local_path, local_root)) {
            return true;
        }
    }

    for (machine.workspaces) |record| {
        if (std.mem.eql(u8, record.remote_path, candidate) and !std.mem.eql(u8, record.local_path, local_root)) {
            return true;
        }
    }

    return false;
}

fn resolvedRecord(
    records: []const model.WorkspaceRecord,
    local_path: []const u8,
) ?model.WorkspaceRecord {
    for (records) |record| {
        if (std.mem.eql(u8, record.local_path, local_path)) return record;
    }

    return null;
}

fn upsertRecord(
    allocator: std.mem.Allocator,
    records: *std.ArrayListUnmanaged(model.WorkspaceRecord),
    incoming: model.WorkspaceRecord,
) void {
    for (records.items) |*existing| {
        if (!std.mem.eql(u8, existing.local_path, incoming.local_path)) continue;

        existing.* = mergeRecord(existing.*, incoming);
        return;
    }

    records.append(allocator, incoming) catch unreachable;
}

fn mergeRecord(
    existing: model.WorkspaceRecord,
    incoming: model.WorkspaceRecord,
) model.WorkspaceRecord {
    return .{
        .name = incoming.name orelse existing.name,
        .local_path = incoming.local_path,
        .remote_path = incoming.remote_path,
        .tmux_session = incoming.tmux_session orelse existing.tmux_session,
    };
}

fn matchesSelector(
    record: model.WorkspaceRecord,
    selector: []const u8,
) bool {
    return std.mem.eql(u8, recordName(record), selector) or
        std.mem.eql(u8, record.local_path, selector) or
        std.mem.eql(u8, record.remote_path, selector);
}

fn parseSelectorIndex(selector: []const u8) ?usize {
    if (selector.len == 0) return null;

    const raw = if (selector[0] == '#') selector[1..] else selector;
    if (raw.len == 0) return null;

    return std.fmt.parseUnsigned(usize, raw, 10) catch null;
}

fn trackedByIndex(
    machine: model.MachineRecord,
    index: usize,
) ?model.WorkspaceRecord {
    if (index == 0) return null;

    if (machine.workspaces.len > 0) {
        if (index > machine.workspaces.len) return null;
        return machine.workspaces[index - 1];
    }

    if (index == 1) {
        return machine.workspace;
    }

    return null;
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

test "rebuild workspace from saved record" {
    const allocator = std.testing.allocator;
    const resolved = try fromRecord(allocator, .{
        .local_path = "/tmp/project",
        .remote_path = "$HOME/work/project",
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/project", resolved.local_root);
    try std.testing.expectEqualStrings("/tmp/project", resolved.current_dir);
    try std.testing.expectEqualStrings("$HOME/work/project", resolved.remote_root);
    try std.testing.expectEqualStrings("project", resolved.name);
}

test "detect repo-local bootstrap hook" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".rove");
    try tmp.dir.writeFile(.{
        .sub_path = ".rove/bootstrap.sh",
        .data = "#!/usr/bin/env bash\n",
    });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const resolved = ResolvedWorkspace{
        .local_root = try allocator.dupe(u8, tmp_path),
        .current_dir = try allocator.dupe(u8, tmp_path),
        .remote_root = try allocator.dupe(u8, "$HOME/work/project"),
        .name = try allocator.dupe(u8, "project"),
    };
    defer resolved.deinit(allocator);

    const hook_path = (try localBootstrapHookPath(allocator, resolved)).?;
    defer allocator.free(hook_path);

    try std.testing.expect(std.mem.endsWith(u8, hook_path, ".rove/bootstrap.sh"));
}

test "merge tracked workspaces preserves older tmux session" {
    const allocator = std.testing.allocator;
    const tracked = try mergeTracked(allocator, .{
        .name = "devbox",
        .provider = .fly,
        .id = "machine-1",
        .host = "devbox.fly.dev",
        .ssh_user = "rove",
        .workspace = .{
            .name = "project",
            .local_path = "/tmp/project",
            .remote_path = "$HOME/work/project",
            .tmux_session = "main",
        },
        .status = .ready,
    }, .{
        .name = "project",
        .local_path = "/tmp/project",
        .remote_path = "$HOME/work/project",
    });
    defer tracked.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tracked.records.len);
    try std.testing.expectEqualStrings("main", tracked.active.tmux_session.?);
}

test "default remote root adds suffix when basename collides" {
    const allocator = std.testing.allocator;
    const remote_root = try defaultRemoteRoot(allocator, .{
        .name = "devbox",
        .provider = .fly,
        .id = "machine-1",
        .host = "devbox.fly.dev",
        .ssh_user = "rove",
        .workspaces = &.{.{
            .name = "project",
            .local_path = "/tmp/project",
            .remote_path = "$HOME/work/project",
        }},
        .status = .ready,
    }, "project", "/tmp/other/project");
    defer allocator.free(remote_root);

    try std.testing.expect(std.mem.startsWith(u8, remote_root, "$HOME/work/project-"));
}

test "resolve tracked selector by local path" {
    const record = try resolveTrackedSelector(.{
        .name = "devbox",
        .provider = .fly,
        .id = "machine-1",
        .host = "devbox.fly.dev",
        .ssh_user = "rove",
        .workspaces = &.{.{
            .name = "project",
            .local_path = "/tmp/project",
            .remote_path = "$HOME/work/project",
        }},
        .status = .ready,
    }, "/tmp/project");

    try std.testing.expectEqualStrings("/tmp/project", record.local_path);
}

test "resolve tracked selector by index" {
    const record = try resolveTrackedSelector(.{
        .name = "devbox",
        .provider = .fly,
        .id = "machine-1",
        .host = "devbox.fly.dev",
        .ssh_user = "rove",
        .workspaces = &.{
            .{
                .name = "one",
                .local_path = "/tmp/one",
                .remote_path = "$HOME/work/one",
            },
            .{
                .name = "two",
                .local_path = "/tmp/two",
                .remote_path = "$HOME/work/two",
            },
        },
        .status = .ready,
    }, "2");

    try std.testing.expectEqualStrings("/tmp/two", record.local_path);
}

test "resolve tracked selector by active alias" {
    const record = try resolveTrackedSelector(.{
        .name = "devbox",
        .provider = .fly,
        .id = "machine-1",
        .host = "devbox.fly.dev",
        .ssh_user = "rove",
        .workspace = .{
            .name = "active",
            .local_path = "/tmp/active",
            .remote_path = "$HOME/work/active",
        },
        .workspaces = &.{
            .{
                .name = "other",
                .local_path = "/tmp/other",
                .remote_path = "$HOME/work/other",
            },
        },
        .status = .ready,
    }, "active");

    try std.testing.expectEqualStrings("/tmp/active", record.local_path);
}

test "resolve tracked selector rejects ambiguous labels" {
    try std.testing.expectError(error.AmbiguousWorkspaceSelector, resolveTrackedSelector(.{
        .name = "devbox",
        .provider = .fly,
        .id = "machine-1",
        .host = "devbox.fly.dev",
        .ssh_user = "rove",
        .workspaces = &.{
            .{
                .name = "project",
                .local_path = "/tmp/one/project",
                .remote_path = "$HOME/work/project",
            },
            .{
                .name = "project",
                .local_path = "/tmp/two/project",
                .remote_path = "$HOME/work/project-2",
            },
        },
        .status = .ready,
    }, "project"));
}
