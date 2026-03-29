const std = @import("std");
const exec = @import("exec.zig");
const model = @import("model.zig");
const ssh = @import("ssh.zig");
const workspace = @import("workspace.zig");

const default_excludes = [_][]const u8{
    ".git/",
    ".direnv/",
    ".devenv/",
    ".zig-cache/",
    "zig-cache/",
    "zig-out/",
    "node_modules/",
    "dist/",
};

const RsyncOptions = struct {
    dry_run: bool = false,
    itemize_changes: bool = false,
};

pub const SyncResult = struct {
    ran_bootstrap_hook: bool = false,
};

pub const PullPreview = struct {
    changes: []u8,

    pub fn deinit(self: PullPreview, allocator: std.mem.Allocator) void {
        allocator.free(self.changes);
    }

    pub fn hasChanges(self: PullPreview) bool {
        return std.mem.trim(u8, self.changes, "\r\n\t ").len > 0;
    }
};

pub fn syncWorkspace(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    resolved: workspace.ResolvedWorkspace,
) !SyncResult {
    try pushWorkspaceFiles(allocator, machine, resolved);
    return .{
        .ran_bootstrap_hook = try runRemoteBootstrapHook(allocator, machine, resolved),
    };
}

pub fn pushWorkspaceFiles(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    resolved: workspace.ResolvedWorkspace,
) !void {
    try ensureRemoteWorkspaceRoot(allocator, machine, resolved.remote_root);

    const source = try std.fmt.allocPrint(allocator, "{s}/", .{resolved.local_root});
    defer allocator.free(source);

    const remote_path = try workspace.quoteRemotePath(allocator, resolved.remote_root);
    defer allocator.free(remote_path);

    const destination = try std.fmt.allocPrint(
        allocator,
        "{s}@{s}:{s}/",
        .{ machine.ssh_user, machine.host, remote_path },
    );
    defer allocator.free(destination);

    var result = try runRsync(allocator, machine, source, destination, .{});
    defer result.deinit(allocator);
}

pub fn pullWorkspaceFiles(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    resolved: workspace.ResolvedWorkspace,
) !void {
    try ensureLocalWorkspaceRoot(resolved.local_root);

    const source = try pullSourceSpec(allocator, machine, resolved.remote_root);
    defer allocator.free(source);

    const destination = try std.fmt.allocPrint(allocator, "{s}/", .{resolved.local_root});
    defer allocator.free(destination);

    var result = try runRsync(allocator, machine, source, destination, .{});
    defer result.deinit(allocator);
}

pub fn previewPullWorkspace(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    resolved: workspace.ResolvedWorkspace,
) !PullPreview {
    const source = try pullSourceSpec(allocator, machine, resolved.remote_root);
    defer allocator.free(source);

    const destination = try std.fmt.allocPrint(allocator, "{s}/", .{resolved.local_root});
    defer allocator.free(destination);

    const result = try runRsync(allocator, machine, source, destination, .{
        .dry_run = true,
        .itemize_changes = true,
    });
    defer allocator.free(result.stderr);

    return .{
        .changes = result.stdout,
    };
}

pub fn runRemoteBootstrapHook(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    resolved: workspace.ResolvedWorkspace,
) !bool {
    const local_hook_path = try workspace.localBootstrapHookPath(allocator, resolved);
    defer if (local_hook_path) |path| allocator.free(path);

    if (local_hook_path == null) {
        return false;
    }

    const remote_root = try workspace.quoteRemotePath(allocator, resolved.remote_root);
    defer allocator.free(remote_root);

    const remote_command = try std.fmt.allocPrint(
        allocator,
        \\cd {s}
        \\if [[ ! -f ./{s} ]]; then
        \\  echo "missing workspace bootstrap hook" >&2
        \\  exit 1
        \\fi
        \\chmod 700 ./{s}
        \\bash ./{s}
        \\
    ,
        .{
            remote_root,
            workspace.bootstrap_hook_path,
            workspace.bootstrap_hook_path,
            workspace.bootstrap_hook_path,
        },
    );
    defer allocator.free(remote_command);

    const result = try ssh.runBatchCommand(allocator, machine, remote_command);
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stdout.len > 0) {
            std.debug.print("[error] workspace bootstrap stdout\n{s}", .{result.stdout});
        }
        if (result.stderr.len > 0) {
            std.debug.print("[error] workspace bootstrap stderr\n{s}", .{result.stderr});
        }
        return error.CommandFailed;
    }

    return true;
}

fn ensureRemoteWorkspaceRoot(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_root: []const u8,
) !void {
    const quoted_remote_root = try workspace.quoteRemotePath(allocator, remote_root);
    defer allocator.free(quoted_remote_root);

    const mkdir_command = try std.fmt.allocPrint(allocator, "mkdir -p {s}", .{quoted_remote_root});
    defer allocator.free(mkdir_command);

    const mkdir_result = try ssh.runBatchCommand(allocator, machine, mkdir_command);
    defer mkdir_result.deinit(allocator);

    if (!mkdir_result.succeeded()) {
        if (mkdir_result.stderr.len > 0) {
            std.debug.print("[error] remote workspace mkdir failed\n{s}", .{mkdir_result.stderr});
        }
        return error.CommandFailed;
    }
}

fn ensureLocalWorkspaceRoot(local_root: []const u8) !void {
    if (std.fs.path.isAbsolute(local_root)) {
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        try root.makePath(std.mem.trimLeft(u8, local_root, "/"));
        return;
    }

    try std.fs.cwd().makePath(local_root);
}

fn pullSourceSpec(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_root: []const u8,
) ![]u8 {
    const remote_path = try workspace.quoteRemotePath(allocator, remote_root);
    defer allocator.free(remote_path);

    return std.fmt.allocPrint(
        allocator,
        "{s}@{s}:{s}/",
        .{ machine.ssh_user, machine.host, remote_path },
    );
}

fn runRsync(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    source: []const u8,
    destination: []const u8,
    options: RsyncOptions,
) !exec.Result {
    const transport = try ssh.rsyncTransportCommand(allocator, machine);
    defer allocator.free(transport);

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &.{ "rsync", "-az", "-e", transport });
    if (options.dry_run) {
        try args.append(allocator, "--dry-run");
    }
    if (options.itemize_changes) {
        try args.append(allocator, "--itemize-changes");
    }
    for (default_excludes) |pattern| {
        try args.appendSlice(allocator, &.{ "--exclude", pattern });
    }
    try args.appendSlice(allocator, &.{ source, destination });

    const result = try exec.run(allocator, args.items);
    errdefer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stderr.len > 0) {
            std.debug.print("[error] rsync failed\n{s}", .{result.stderr});
        }
        return error.CommandFailed;
    }

    return result;
}

test "preview reports changes when rsync itemized output is non-empty" {
    const preview = PullPreview{
        .changes = "cd+++++++++ src/main.zig\n",
    };

    try std.testing.expect(preview.hasChanges());
}

test "preview reports no changes for whitespace-only output" {
    const preview = PullPreview{
        .changes = "\n",
    };

    try std.testing.expect(!preview.hasChanges());
}
