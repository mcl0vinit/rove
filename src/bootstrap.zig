const std = @import("std");
const model = @import("model.zig");
const ssh = @import("ssh.zig");

pub fn run(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    startup_script: []const u8,
) !void {
    const remote_script_path = try std.fmt.allocPrint(allocator, "/tmp/rove-bootstrap-{s}.sh", .{
        machine.id,
    });
    defer allocator.free(remote_script_path);

    try ssh.uploadFile(allocator, machine, startup_script, remote_script_path);

    const remote_command = try std.fmt.allocPrint(
        allocator,
        "chmod 700 {0s} && bash {0s}; status=$?; rm -f {0s}; exit $status",
        .{remote_script_path},
    );
    defer allocator.free(remote_command);

    const result = try ssh.runBatchCommand(allocator, machine, remote_command);
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stdout.len > 0) {
            std.debug.print("[error] remote bootstrap stdout\n{s}", .{result.stdout});
        }
        if (result.stderr.len > 0) {
            std.debug.print("[error] remote bootstrap stderr\n{s}", .{result.stderr});
        }
        return error.CommandFailed;
    }
}

test "remote script path uses machine id" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "cpu",
        .provider = .fly,
        .id = "machine-123",
        .host = "devbox.fly.dev",
        .ssh_user = "rove",
        .status = .ready,
    };

    const remote_script_path = try std.fmt.allocPrint(allocator, "/tmp/rove-bootstrap-{s}.sh", .{
        machine.id,
    });
    defer allocator.free(remote_script_path);

    try std.testing.expectEqualStrings("/tmp/rove-bootstrap-machine-123.sh", remote_script_path);
}
