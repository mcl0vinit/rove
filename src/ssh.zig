const std = @import("std");
const exec = @import("exec.zig");
const model = @import("model.zig");
const paths = @import("paths.zig");
const shell = @import("shell.zig");

pub const WaitOptions = struct {
    timeout_ms: u64 = 180 * std.time.ms_per_s,
    poll_interval_ms: u64 = 2 * std.time.ms_per_s,
};

const ConnectionParts = struct {
    destination: []u8,
    user_known_hosts: []u8,
    host_key_alias: []u8,
    port_option: []u8,
    identity_file: []u8,

    fn deinit(self: ConnectionParts, allocator: std.mem.Allocator) void {
        allocator.free(self.destination);
        allocator.free(self.user_known_hosts);
        allocator.free(self.host_key_alias);
        allocator.free(self.port_option);
        allocator.free(self.identity_file);
    }
};

pub fn waitForReady(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    options: WaitOptions,
) !void {
    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(options.timeout_ms));
    var last_stderr: ?[]u8 = null;
    defer if (last_stderr) |stderr| allocator.free(stderr);

    while (true) {
        const result = try runBatchCommand(allocator, machine, "true");
        defer result.deinit(allocator);

        if (result.succeeded()) {
            return;
        }

        if (last_stderr) |stderr| allocator.free(stderr);
        last_stderr = if (result.stderr.len > 0)
            try allocator.dupe(u8, result.stderr)
        else
            null;

        if (isFatalFailure(result.stderr)) {
            if (result.stderr.len > 0) {
                std.debug.print("[error] ssh authentication failed\n{s}", .{result.stderr});
            }
            return error.AuthenticationFailed;
        }

        if (std.time.milliTimestamp() >= deadline_ms) {
            if (last_stderr) |stderr| {
                std.debug.print("[error] ssh did not become reachable before timeout\n{s}", .{stderr});
            }
            return error.ConnectTimedOut;
        }

        std.Thread.sleep(options.poll_interval_ms * std.time.ns_per_ms);
    }
}

pub fn runBatchCommand(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
) !exec.Result {
    return runBatchCommandWithRecovery(allocator, machine, remote_command, true);
}

pub fn preflight(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !void {
    const result = try runBatchCommand(allocator, machine, "true");
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stderr.len > 0) {
            std.debug.print("[error] ssh preflight failed\n{s}", .{result.stderr});
        }
        return error.CommandFailed;
    }
}

fn runBatchCommandWithRecovery(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
    allow_host_key_recovery: bool,
) !exec.Result {
    if (machine.provider == .fly and machine.app != null) {
        return runFlyMachineCommand(allocator, machine, remote_command);
    }

    const connection = try prepareConnection(allocator, machine);
    defer connection.deinit(allocator);
    const wrapped_command = try wrappedRemoteCommand(allocator, remote_command);
    defer allocator.free(wrapped_command);

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try appendCommonArgs(allocator, &args, connection, true, true);
    try args.appendSlice(allocator, &.{ "-T", connection.destination, wrapped_command });

    var result = try exec.run(allocator, args.items);
    if (allow_host_key_recovery and !result.succeeded() and isHostKeyMismatch(result.stderr)) {
        result.deinit(allocator);
        if (try clearKnownHostAlias(allocator, machine)) {
            std.debug.print("[warn] cleared stale SSH host key for machine '{s}' and retried\n", .{machine.name});
        }
        return runBatchCommandWithRecovery(allocator, machine, remote_command, false);
    }

    return result;
}

fn runFlyMachineCommand(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
) !exec.Result {
    const app = machine.app orelse machine.provider_scope orelse return error.MissingProviderScope;
    const wrapped_command = try wrappedRemoteCommand(allocator, remote_command);
    defer allocator.free(wrapped_command);

    return exec.run(allocator, &.{
        "flyctl",
        "ssh",
        "console",
        "--quiet",
        "--app",
        app,
        "--machine",
        machine.id,
        "--user",
        machine.ssh_user,
        "--command",
        wrapped_command,
    });
}

pub fn uploadFile(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    local_path: []const u8,
    remote_path: []const u8,
) !void {
    try preflight(allocator, machine);

    const connection = try prepareConnection(allocator, machine);
    defer connection.deinit(allocator);

    const remote_spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{
        connection.destination,
        remote_path,
    });
    defer allocator.free(remote_spec);

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.append(allocator, "scp");
    try args.append(allocator, "-q");
    try appendOpenSshOptions(allocator, &args, connection, true, true);
    try args.appendSlice(allocator, &.{ local_path, remote_spec });

    const result = try exec.run(allocator, args.items);
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stderr.len > 0) {
            std.debug.print("[error] bootstrap upload failed\n{s}", .{result.stderr});
        }
        return error.CommandFailed;
    }
}

pub fn openInteractive(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !std.process.Child.Term {
    try preflight(allocator, machine);

    const connection = try prepareConnection(allocator, machine);
    defer connection.deinit(allocator);

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.append(allocator, "ssh");
    try appendOpenSshOptions(allocator, &args, connection, false, false);
    try args.append(allocator, connection.destination);

    return exec.runInteractive(allocator, args.items);
}

pub fn openInteractiveCommand(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
) !std.process.Child.Term {
    try preflight(allocator, machine);

    const connection = try prepareConnection(allocator, machine);
    defer connection.deinit(allocator);
    const wrapped_command = try wrappedRemoteCommand(allocator, remote_command);
    defer allocator.free(wrapped_command);

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.append(allocator, "ssh");
    try appendOpenSshOptions(allocator, &args, connection, false, false);
    try args.appendSlice(allocator, &.{ "-t", connection.destination, wrapped_command });

    return exec.runInteractive(allocator, args.items);
}

fn prepareConnection(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !ConnectionParts {
    const known_hosts_path = try paths.defaultKnownHostsPath(allocator);
    errdefer allocator.free(known_hosts_path);
    defer allocator.free(known_hosts_path);

    if (std.fs.path.dirname(known_hosts_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    const destination = try std.fmt.allocPrint(allocator, "{s}@{s}", .{
        machine.ssh_user,
        machine.host,
    });
    errdefer allocator.free(destination);

    const user_known_hosts = try std.fmt.allocPrint(allocator, "UserKnownHostsFile={s}", .{
        known_hosts_path,
    });
    errdefer allocator.free(user_known_hosts);

    const host_key_alias = try std.fmt.allocPrint(allocator, "HostKeyAlias={s}", .{
        machine.id,
    });
    errdefer allocator.free(host_key_alias);

    const port_option = try std.fmt.allocPrint(allocator, "Port={d}", .{
        machine.ssh_port,
    });
    errdefer allocator.free(port_option);

    const identity_file = try paths.defaultManagedPrivateKeyPath(allocator);
    errdefer allocator.free(identity_file);

    return .{
        .destination = destination,
        .user_known_hosts = user_known_hosts,
        .host_key_alias = host_key_alias,
        .port_option = port_option,
        .identity_file = identity_file,
    };
}

fn appendCommonArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayListUnmanaged([]const u8),
    connection: ConnectionParts,
    batch_mode: bool,
    quiet: bool,
) !void {
    try args.append(allocator, "ssh");
    try appendOpenSshOptions(allocator, args, connection, batch_mode, quiet);
}

fn wrappedRemoteCommand(
    allocator: std.mem.Allocator,
    remote_command: []const u8,
) ![]u8 {
    const quoted = try shell.quote(allocator, remote_command);
    defer allocator.free(quoted);

    return std.fmt.allocPrint(allocator, "/bin/bash -lc {s}", .{quoted});
}

fn appendOpenSshOptions(
    allocator: std.mem.Allocator,
    args: *std.ArrayListUnmanaged([]const u8),
    connection: ConnectionParts,
    batch_mode: bool,
    quiet: bool,
) !void {
    if (batch_mode) {
        try args.appendSlice(allocator, &.{ "-o", "BatchMode=yes" });
    }

    try args.appendSlice(allocator, &.{
        "-i",
        connection.identity_file,
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "PreferredAuthentications=publickey",
        "-o",
        "ForwardAgent=no",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        connection.user_known_hosts,
        "-o",
        connection.host_key_alias,
        "-o",
        connection.port_option,
        "-o",
        "ConnectTimeout=5",
    });

    if (quiet) {
        try args.appendSlice(allocator, &.{ "-o", "LogLevel=ERROR" });
    }
}

fn clearKnownHostAlias(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !bool {
    const known_hosts_path = try paths.defaultKnownHostsPath(allocator);
    defer allocator.free(known_hosts_path);

    std.fs.cwd().access(known_hosts_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    const result = try exec.run(allocator, &.{
        "ssh-keygen",
        "-R",
        machine.id,
        "-f",
        known_hosts_path,
    });
    defer result.deinit(allocator);

    return result.succeeded();
}

fn isHostKeyMismatch(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "Host key verification failed") != null or
        std.mem.indexOf(u8, stderr, "REMOTE HOST IDENTIFICATION HAS CHANGED") != null or
        std.mem.indexOf(u8, stderr, "Offending ED25519 key") != null or
        std.mem.indexOf(u8, stderr, "host key for") != null;
}

fn isFatalFailure(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "Permission denied") != null or
        isHostKeyMismatch(stderr) or
        std.mem.indexOf(u8, stderr, "Too many authentication failures") != null;
}

test "treat authentication issues as fatal" {
    try std.testing.expect(isFatalFailure("Permission denied (publickey).\n"));
    try std.testing.expect(isFatalFailure("Host key verification failed.\n"));
    try std.testing.expect(!isFatalFailure("ssh: connect to host devbox.fly.dev port 22: Connection refused\n"));
}

test "detect stale host key failures" {
    try std.testing.expect(isHostKeyMismatch("Host key verification failed.\n"));
    try std.testing.expect(isHostKeyMismatch("Offending ED25519 key in /tmp/known_hosts:1\n"));
    try std.testing.expect(!isHostKeyMismatch("Permission denied (publickey).\n"));
}
