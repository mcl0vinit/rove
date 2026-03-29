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

pub fn pushWorkspace(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    resolved: workspace.ResolvedWorkspace,
) !void {
    const remote_dir = try workspace.quoteRemotePath(allocator, resolved.remote_root);
    defer allocator.free(remote_dir);

    const mkdir_command = try std.fmt.allocPrint(allocator, "mkdir -p {s}", .{remote_dir});
    defer allocator.free(mkdir_command);

    const mkdir_result = try ssh.runBatchCommand(allocator, machine, mkdir_command);
    defer mkdir_result.deinit(allocator);

    if (!mkdir_result.succeeded()) {
        if (mkdir_result.stderr.len > 0) {
            std.debug.print("[error] remote workspace mkdir failed\n{s}", .{mkdir_result.stderr});
        }
        return error.CommandFailed;
    }

    const transport = try ssh.rsyncTransportCommand(allocator, machine);
    defer allocator.free(transport);

    const source = try std.fmt.allocPrint(allocator, "{s}/", .{resolved.local_root});
    defer allocator.free(source);

    const destination_path = try workspace.quoteRemotePath(allocator, resolved.remote_root);
    defer allocator.free(destination_path);

    const destination = try std.fmt.allocPrint(
        allocator,
        "{s}@{s}:{s}/",
        .{ machine.ssh_user, machine.host, destination_path },
    );
    defer allocator.free(destination);

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &.{ "rsync", "-az", "-e", transport });
    for (default_excludes) |pattern| {
        try args.appendSlice(allocator, &.{ "--exclude", pattern });
    }
    try args.appendSlice(allocator, &.{ source, destination });

    const result = try exec.run(allocator, args.items);
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stderr.len > 0) {
            std.debug.print("[error] rsync push failed\n{s}", .{result.stderr});
        }
        return error.CommandFailed;
    }
}
