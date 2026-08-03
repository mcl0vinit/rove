const std = @import("std");
const exec = @import("exec.zig");
const model = @import("model.zig");
const paths = @import("paths.zig");
const shell = @import("shell.zig");

pub const WaitOptions = struct {
    timeout_ms: u64 = 180 * std.time.ms_per_s,
    poll_interval_ms: u64 = 2 * std.time.ms_per_s,
};

pub const WaitResult = struct {
    endpoint: ?EndpointMetadata = null,

    pub fn deinit(self: WaitResult, allocator: std.mem.Allocator) void {
        if (self.endpoint) |endpoint| endpoint.deinit(allocator);
    }
};

const CommandRunner = *const fn (
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) anyerror!exec.Result;

const BatchCommandOptions = struct {
    allow_host_key_recovery: bool = true,
    emit_resolution_errors: bool = true,
};

const EndpointResolutionMode = enum {
    refresh,
    prefer_existing,
};

pub const EndpointMetadata = struct {
    configured_host: []u8,
    resolved_host: ?[]u8 = null,
    endpoint_host: []const u8,
    resolver: model.SshResolver,

    pub fn deinit(self: EndpointMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.configured_host);
        if (self.resolved_host) |resolved_host| allocator.free(resolved_host);
    }

    pub fn applyToMachine(self: EndpointMetadata, machine: *model.MachineRecord) void {
        machine.ssh_configured_host = self.configured_host;
        machine.ssh_resolved_host = self.resolved_host;
    }
};

const ConnectionParts = struct {
    endpoint: ?EndpointMetadata = null,
    destination: []u8,
    user_known_hosts: []u8,
    host_key_alias: []u8,
    port_option: []u8,
    identity_file: []u8,

    fn deinit(self: ConnectionParts, allocator: std.mem.Allocator) void {
        if (self.endpoint) |endpoint| endpoint.deinit(allocator);
        allocator.free(self.destination);
        allocator.free(self.user_known_hosts);
        allocator.free(self.host_key_alias);
        allocator.free(self.port_option);
        allocator.free(self.identity_file);
    }
};

const BatchCommandResult = struct {
    result: exec.Result,
    endpoint: ?EndpointMetadata = null,

    fn deinit(self: BatchCommandResult, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        if (self.endpoint) |endpoint| endpoint.deinit(allocator);
    }
};

pub fn waitForReady(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    options: WaitOptions,
) !WaitResult {
    return waitForReadyWithRunner(allocator, machine, options, exec.run);
}

fn waitForReadyWithRunner(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    options: WaitOptions,
    runner: CommandRunner,
) !WaitResult {
    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(options.timeout_ms));
    var last_stderr: ?[]u8 = null;
    defer if (last_stderr) |stderr| allocator.free(stderr);

    while (true) {
        var batch = runBatchCommandWithMetadataAndRunner(allocator, machine, "true", .{
            .allow_host_key_recovery = true,
            .emit_resolution_errors = false,
        }, runner) catch |err| switch (err) {
            error.SshResolutionFailed => {
                if (last_stderr) |stderr| allocator.free(stderr);
                last_stderr = try std.fmt.allocPrint(
                    allocator,
                    "ssh resolver '{s}' did not resolve host '{s}': {s}\n",
                    .{
                        model.sshResolverName(machine.ssh_resolver),
                        model.configuredSshHost(machine),
                        @errorName(err),
                    },
                );

                if (std.time.milliTimestamp() >= deadline_ms) {
                    if (last_stderr) |stderr| {
                        std.debug.print("[error] ssh did not become reachable before timeout\n{s}", .{stderr});
                    }
                    return err;
                }

                std.Thread.sleep(options.poll_interval_ms * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer batch.deinit(allocator);

        if (batch.result.succeeded()) {
            const endpoint = batch.endpoint;
            batch.endpoint = null;
            return .{ .endpoint = endpoint };
        }

        if (last_stderr) |stderr| allocator.free(stderr);
        last_stderr = if (batch.result.stderr.len > 0)
            try allocator.dupe(u8, batch.result.stderr)
        else
            null;

        if (isFatalFailure(batch.result.stderr)) {
            if (batch.result.stderr.len > 0) {
                std.debug.print("[error] ssh authentication failed\n{s}", .{batch.result.stderr});
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

pub fn waitForCommand(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
    options: WaitOptions,
) !void {
    return waitForCommandWithRunner(allocator, machine, remote_command, options, exec.run);
}

fn waitForCommandWithRunner(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
    options: WaitOptions,
    runner: CommandRunner,
) !void {
    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(options.timeout_ms));

    while (true) {
        const result = try runBatchCommandWithRecoveryAndRunner(allocator, machine, remote_command, .{
            .allow_host_key_recovery = true,
            .emit_resolution_errors = false,
        }, runner);
        defer result.deinit(allocator);

        if (result.succeeded()) {
            return;
        }

        if (isFatalFailure(result.stderr)) {
            return error.AuthenticationFailed;
        }

        if (std.time.milliTimestamp() >= deadline_ms) {
            return error.ReadinessCommandTimedOut;
        }

        std.Thread.sleep(options.poll_interval_ms * std.time.ns_per_ms);
    }
}

pub fn runBatchCommand(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
) !exec.Result {
    return runBatchCommandWithRecoveryAndRunner(allocator, machine, remote_command, .{}, exec.run);
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

fn runBatchCommandWithRecoveryAndRunner(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
    options: BatchCommandOptions,
    runner: CommandRunner,
) !exec.Result {
    const batch = try runBatchCommandWithMetadataAndRunner(allocator, machine, remote_command, options, runner);
    if (batch.endpoint) |endpoint| endpoint.deinit(allocator);
    return batch.result;
}

fn runBatchCommandWithMetadataAndRunner(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
    options: BatchCommandOptions,
    runner: CommandRunner,
) !BatchCommandResult {
    if (shouldUseFlyMachineCommand(machine)) {
        return .{
            .result = try runFlyMachineCommandWithRunner(allocator, machine, remote_command, runner),
        };
    }

    var connection = prepareConnectionWithRunner(allocator, machine, runner) catch |err| {
        if (options.emit_resolution_errors and isResolutionError(err)) {
            printResolutionFailure(machine, err);
        }
        return err;
    };
    defer connection.deinit(allocator);
    const wrapped_command = try wrappedRemoteCommand(allocator, remote_command);
    defer allocator.free(wrapped_command);

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try appendCommonArgs(allocator, &args, connection, true, true);
    try args.appendSlice(allocator, &.{ "-T", connection.destination, wrapped_command });

    var result = try runner(allocator, args.items);
    if (options.allow_host_key_recovery and !result.succeeded() and isHostKeyMismatch(result.stderr)) {
        result.deinit(allocator);
        if (try clearKnownHostAlias(allocator, machine)) {
            std.debug.print("[warn] cleared stale SSH host key for machine '{s}' and retried\n", .{machine.name});
        }
        return runBatchCommandWithMetadataAndRunner(allocator, machine, remote_command, .{
            .allow_host_key_recovery = false,
            .emit_resolution_errors = options.emit_resolution_errors,
        }, runner);
    }

    const endpoint = connection.endpoint;
    connection.endpoint = null;
    return .{
        .result = result,
        .endpoint = endpoint,
    };
}

fn shouldUseFlyMachineCommand(machine: model.MachineRecord) bool {
    if (machine.ssh_resolver != .system) return false;
    if (machine.require_private_ssh) return false;
    if (machine.provider != .fly) return false;
    const app = machine.app orelse return false;
    if (machine.ssh_port != 22) return false;
    return isDefaultFlySshHost(app, model.configuredSshHost(machine));
}

fn isDefaultFlySshHost(app: []const u8, host: []const u8) bool {
    const suffix = ".fly.dev";
    if (host.len != app.len + suffix.len) return false;
    return std.mem.startsWith(u8, host, app) and std.mem.endsWith(u8, host, suffix);
}

fn runFlyMachineCommand(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
) !exec.Result {
    return runFlyMachineCommandWithRunner(allocator, machine, remote_command, exec.run);
}

fn runFlyMachineCommandWithRunner(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    remote_command: []const u8,
    runner: CommandRunner,
) !exec.Result {
    const app = machine.app orelse machine.provider_scope orelse return error.MissingProviderScope;
    const wrapped_command = try wrappedRemoteCommand(allocator, remote_command);
    defer allocator.free(wrapped_command);

    return runner(allocator, &.{
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
    return prepareConnectionWithRunner(allocator, machine, exec.run);
}

fn prepareConnectionWithRunner(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    runner: CommandRunner,
) !ConnectionParts {
    var endpoint = try resolveEndpointMetadataWithRunner(allocator, machine, runner, .prefer_existing);
    errdefer endpoint.deinit(allocator);

    const known_hosts_path = try paths.defaultKnownHostsPath(allocator);
    errdefer allocator.free(known_hosts_path);
    defer allocator.free(known_hosts_path);

    if (std.fs.path.dirname(known_hosts_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    const destination = try std.fmt.allocPrint(allocator, "{s}@{s}", .{
        machine.ssh_user,
        endpoint.endpoint_host,
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

    const identity_file = if (machine.ssh_identity_file) |configured|
        try paths.expandUserPath(allocator, configured)
    else
        try paths.defaultManagedPrivateKeyPath(allocator);
    errdefer allocator.free(identity_file);

    return .{
        .endpoint = endpoint,
        .destination = destination,
        .user_known_hosts = user_known_hosts,
        .host_key_alias = host_key_alias,
        .port_option = port_option,
        .identity_file = identity_file,
    };
}

pub fn resolveEndpointMetadata(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !EndpointMetadata {
    return resolveEndpointMetadataWithRunner(allocator, machine, exec.run, .refresh);
}

fn resolveEndpointMetadataWithRunner(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    runner: CommandRunner,
    mode: EndpointResolutionMode,
) !EndpointMetadata {
    const configured_host = try allocator.dupe(u8, model.configuredSshHost(machine));
    errdefer allocator.free(configured_host);

    if (machine.require_private_ssh and machine.ssh_resolver != .tailscale) {
        return error.PrivateSshRequiresPrivateResolver;
    }

    switch (machine.ssh_resolver) {
        .system, .none => {
            return .{
                .configured_host = configured_host,
                .endpoint_host = configured_host,
                .resolver = machine.ssh_resolver,
            };
        },
        .tailscale => {
            if (mode == .prefer_existing) {
                if (machine.ssh_resolved_host) |existing| {
                    const resolved_host = try allocator.dupe(u8, existing);
                    errdefer allocator.free(resolved_host);

                    return .{
                        .configured_host = configured_host,
                        .resolved_host = resolved_host,
                        .endpoint_host = resolved_host,
                        .resolver = machine.ssh_resolver,
                    };
                }
            }

            const resolved_host = try resolveTailscaleHostWithRunner(allocator, configured_host, runner);
            errdefer allocator.free(resolved_host);

            return .{
                .configured_host = configured_host,
                .resolved_host = resolved_host,
                .endpoint_host = resolved_host,
                .resolver = machine.ssh_resolver,
            };
        },
    }
}

fn resolveTailscaleHostWithRunner(
    allocator: std.mem.Allocator,
    host: []const u8,
    runner: CommandRunner,
) ![]u8 {
    if (runner(allocator, &.{ "tailscale", "status", "--json" })) |status_result| {
        defer status_result.deinit(allocator);
        if (status_result.succeeded()) {
            const resolved = resolveTailscaleHostFromStatus(allocator, host, status_result.stdout) catch |err| switch (err) {
                error.NoMatchingTailscalePeer, error.MalformedTailscaleStatus => null,
                error.NoOnlineTailscalePeer, error.MatchingTailscalePeerMissingIpv4 => return error.SshResolutionFailed,
                else => |other| return other,
            };
            if (resolved) |ip| return ip;
        }
    } else |_| {}

    return resolveTailscaleHostWithIpCommand(allocator, host, runner);
}

fn resolveTailscaleHostWithIpCommand(
    allocator: std.mem.Allocator,
    host: []const u8,
    runner: CommandRunner,
) ![]u8 {
    const result = runner(allocator, &.{ "tailscale", "ip", "-4", host }) catch {
        return error.SshResolutionFailed;
    };
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        return error.SshResolutionFailed;
    }

    return parseTailscaleIpv4Output(allocator, result.stdout);
}

fn resolveTailscaleHostFromStatus(
    allocator: std.mem.Allocator,
    host: []const u8,
    status_json: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, status_json, .{
        .max_value_len = 4 * 1024 * 1024,
    }) catch return error.MalformedTailscaleStatus;
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedTailscaleStatus;
    const peers_value = parsed.value.object.get("Peer") orelse return error.NoMatchingTailscalePeer;
    if (peers_value != .object) return error.MalformedTailscaleStatus;

    var matched: usize = 0;
    var online_matched: usize = 0;
    var best_ip: ?[]const u8 = null;
    var best_created: []const u8 = "";

    var iterator = peers_value.object.iterator();
    while (iterator.next()) |entry| {
        const peer_value = entry.value_ptr.*;
        if (peer_value != .object) continue;
        if (!tailscalePeerMatchesHost(peer_value, host)) continue;
        matched += 1;

        if (!(boolField(peer_value, "Online") orelse false)) continue;
        online_matched += 1;

        const ip = firstIpv4TailscaleIp(peer_value) orelse continue;
        const created = stringField(peer_value, "Created") orelse "";
        if (best_ip == null or std.mem.order(u8, created, best_created) == .gt) {
            best_ip = ip;
            best_created = created;
        }
    }

    if (best_ip) |ip| return allocator.dupe(u8, ip);
    if (online_matched > 0) return error.MatchingTailscalePeerMissingIpv4;
    if (matched > 0) return error.NoOnlineTailscalePeer;
    return error.NoMatchingTailscalePeer;
}

fn tailscalePeerMatchesHost(peer_value: std.json.Value, host: []const u8) bool {
    if (stringField(peer_value, "HostName")) |hostname| {
        if (std.mem.eql(u8, hostname, host)) return true;
    }
    if (stringField(peer_value, "DNSName")) |dns_name| {
        return dnsNameMatchesHost(dns_name, host);
    }
    return false;
}

fn dnsNameMatchesHost(dns_name: []const u8, host: []const u8) bool {
    if (!std.mem.startsWith(u8, dns_name, host)) return false;
    if (dns_name.len == host.len) return true;
    return dns_name[host.len] == '.';
}

fn firstIpv4TailscaleIp(peer_value: std.json.Value) ?[]const u8 {
    const ips_value = peer_value.object.get("TailscaleIPs") orelse return null;
    if (ips_value != .array) return null;
    for (ips_value.array.items) |ip_value| {
        if (ip_value != .string) continue;
        _ = std.net.Address.parseIp4(ip_value.string, 0) catch continue;
        return ip_value.string;
    }
    return null;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .bool => |flag| flag,
        else => null,
    };
}

fn parseTailscaleIpv4Output(
    allocator: std.mem.Allocator,
    output: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (trimmed.len == 0) return error.SshResolutionFailed;

    var tokens = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    const ip = tokens.next() orelse return error.SshResolutionFailed;
    if (tokens.next() != null) return error.SshResolutionFailed;

    _ = std.net.Address.parseIp4(ip, 0) catch return error.SshResolutionFailed;
    return allocator.dupe(u8, ip);
}

fn isResolutionError(err: anyerror) bool {
    return err == error.SshResolutionFailed or
        err == error.PrivateSshRequiresPrivateResolver;
}

fn printResolutionFailure(machine: model.MachineRecord, err: anyerror) void {
    std.debug.print(
        "[error] ssh resolver '{s}' failed for host '{s}': {s}\n",
        .{
            model.sshResolverName(machine.ssh_resolver),
            model.configuredSshHost(machine),
            @errorName(err),
        },
    );
    if (machine.require_private_ssh) {
        std.debug.print("[hint] private SSH is required; no system or public SSH fallback was attempted\n", .{});
    } else if (machine.ssh_resolver == .tailscale) {
        std.debug.print("[hint] confirm `tailscale ip -4 {s}` succeeds locally\n", .{model.configuredSshHost(machine)});
    }
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

    return std.fmt.allocPrint(allocator, "/bin/bash -c {s}", .{quoted});
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
        "-F",
        "/dev/null",
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

test "fly machine command is only used for default fly ssh endpoint" {
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .provider_scope = "devbox",
        .app = "devbox",
        .host = "devbox.fly.dev",
        .ssh_port = 22,
        .ssh_user = "rove",
    };

    try std.testing.expect(shouldUseFlyMachineCommand(machine));
}

test "private fly ssh endpoint uses direct openssh transport" {
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .provider_scope = "devbox",
        .app = "devbox",
        .host = "mesh-work",
        .ssh_port = 2222,
        .ssh_user = "rove",
    };

    try std.testing.expect(!shouldUseFlyMachineCommand(machine));
}

test "tailscale resolver disables fly machine ssh shortcut" {
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .provider_scope = "devbox",
        .app = "devbox",
        .host = "devbox.fly.dev",
        .ssh_port = 22,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    try std.testing.expect(!shouldUseFlyMachineCommand(machine));
}

test "parse tailscale ipv4 resolver output" {
    const allocator = std.testing.allocator;
    const ip = try parseTailscaleIpv4Output(allocator, "100.64.1.2\n");
    defer allocator.free(ip);

    try std.testing.expectEqualStrings("100.64.1.2", ip);
}

test "reject empty and malformed tailscale resolver output" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.SshResolutionFailed, parseTailscaleIpv4Output(allocator, "\n"));
    try std.testing.expectError(error.SshResolutionFailed, parseTailscaleIpv4Output(allocator, "not-an-ip\n"));
    try std.testing.expectError(error.SshResolutionFailed, parseTailscaleIpv4Output(allocator, "100.64.1.2\n100.64.1.3\n"));
}

test "tailscale status resolver prefers newest online duplicate hostname" {
    const allocator = std.testing.allocator;
    const ip = try resolveTailscaleHostFromStatus(allocator, "mesh-mesh-demo-a",
        \\{
        \\  "Peer": {
        \\    "old": {
        \\      "HostName": "mesh-mesh-demo-a",
        \\      "DNSName": "mesh-mesh-demo-a.tailnet.ts.net.",
        \\      "Online": false,
        \\      "Created": "2026-06-26T14:49:49Z",
        \\      "TailscaleIPs": ["100.111.145.3", "fd7a:115c:a1e0::1"]
        \\    },
        \\    "middle": {
        \\      "HostName": "mesh-mesh-demo-a",
        \\      "DNSName": "mesh-mesh-demo-a-1.tailnet.ts.net.",
        \\      "Online": true,
        \\      "Created": "2026-06-26T15:02:54Z",
        \\      "TailscaleIPs": ["100.94.84.59"]
        \\    },
        \\    "new": {
        \\      "HostName": "mesh-mesh-demo-a",
        \\      "DNSName": "mesh-mesh-demo-a-2.tailnet.ts.net.",
        \\      "Online": true,
        \\      "Created": "2026-06-26T15:24:51Z",
        \\      "TailscaleIPs": ["100.101.236.39"]
        \\    }
        \\  }
        \\}
    );
    defer allocator.free(ip);

    try std.testing.expectEqualStrings("100.101.236.39", ip);
}

test "tailscale status resolver refuses offline stale duplicate hostnames" {
    try std.testing.expectError(error.NoOnlineTailscalePeer, resolveTailscaleHostFromStatus(std.testing.allocator, "mesh-mesh-demo-a",
        \\{
        \\  "Peer": {
        \\    "old": {
        \\      "HostName": "mesh-mesh-demo-a",
        \\      "DNSName": "mesh-mesh-demo-a.tailnet.ts.net.",
        \\      "Online": false,
        \\      "Created": "2026-06-26T14:49:49Z",
        \\      "TailscaleIPs": ["100.111.145.3"]
        \\    }
        \\  }
        \\}
    ));
}

test "tailscale resolver records configured and resolved hosts" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_port = 2222,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    const endpoint = try resolveEndpointMetadataWithRunner(allocator, machine, fakeTailscaleSuccess, .refresh);
    defer endpoint.deinit(allocator);

    try std.testing.expectEqualStrings("private-work", endpoint.configured_host);
    try std.testing.expectEqualStrings("100.64.1.2", endpoint.resolved_host.?);
    try std.testing.expectEqualStrings("100.64.1.2", endpoint.endpoint_host);
}

test "ssh readiness returns successful endpoint metadata" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_port = 2222,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    const ready = try waitForReadyWithRunner(allocator, machine, .{
        .timeout_ms = 0,
        .poll_interval_ms = 1,
    }, fakeReadyRunner);
    defer ready.deinit(allocator);

    try std.testing.expect(ready.endpoint != null);
    try std.testing.expectEqualStrings("private-work", ready.endpoint.?.configured_host);
    try std.testing.expectEqualStrings("100.64.1.2", ready.endpoint.?.resolved_host.?);
    try std.testing.expectEqualStrings("100.64.1.2", ready.endpoint.?.endpoint_host);
}

test "ssh readiness fails closed when private resolver policy is invalid" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_port = 2222,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    try std.testing.expectError(
        error.PrivateSshRequiresPrivateResolver,
        waitForReadyWithRunner(allocator, machine, .{
            .timeout_ms = 0,
            .poll_interval_ms = 1,
        }, fakeReadyRunner),
    );
}

test "generic readiness command succeeds through ssh" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_configured_host = "private-work",
        .ssh_resolved_host = "100.64.1.2",
        .ssh_port = 2222,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    try waitForCommandWithRunner(allocator, machine, "test -f /tmp/app-ready", .{
        .timeout_ms = 0,
        .poll_interval_ms = 1,
    }, fakeReadyRunner);
}

test "generic readiness command timeout does not print command output" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_configured_host = "private-work",
        .ssh_resolved_host = "100.64.1.2",
        .ssh_port = 2222,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    try std.testing.expectError(
        error.ReadinessCommandTimedOut,
        waitForCommandWithRunner(allocator, machine, "test -f /tmp/app-ready", .{
            .timeout_ms = 0,
            .poll_interval_ms = 1,
        }, fakeReadinessFailureRunner),
    );
}

test "tailscale resolver command failure fails closed" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_port = 2222,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    try std.testing.expectError(
        error.SshResolutionFailed,
        resolveEndpointMetadataWithRunner(allocator, machine, fakeTailscaleFailure, .refresh),
    );
}

test "private ssh policy rejects non-private resolver before connection" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_port = 2222,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    try std.testing.expectError(
        error.PrivateSshRequiresPrivateResolver,
        resolveEndpointMetadataWithRunner(allocator, machine, fakeTailscaleSuccess, .refresh),
    );
}

test "fresh tailscale resolution ignores previously recorded endpoint" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_configured_host = "private-work",
        .ssh_resolved_host = "100.64.9.9",
        .ssh_port = 2222,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    const endpoint = try resolveEndpointMetadataWithRunner(allocator, machine, fakeTailscaleSuccess, .refresh);
    defer endpoint.deinit(allocator);

    try std.testing.expectEqualStrings("100.64.1.2", endpoint.resolved_host.?);
    try std.testing.expectEqualStrings("100.64.1.2", endpoint.endpoint_host);
}

test "prepared connection reuses recorded resolved endpoint" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_configured_host = "private-work",
        .ssh_resolved_host = "100.64.9.9",
        .ssh_port = 2222,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    const connection = try prepareConnectionWithRunner(allocator, machine, fakeTailscaleFailure);
    defer connection.deinit(allocator);

    try std.testing.expectEqualStrings("rove@100.64.9.9", connection.destination);
}

test "tailscale resolved endpoint is used as ssh destination" {
    const allocator = std.testing.allocator;
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .host = "private-work",
        .ssh_port = 2222,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
    };

    const connection = try prepareConnectionWithRunner(allocator, machine, fakeTailscaleSuccess);
    defer connection.deinit(allocator);

    try std.testing.expectEqualStrings("rove@100.64.1.2", connection.destination);
}

test "openssh args ignore user ssh config" {
    const allocator = std.testing.allocator;
    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try appendOpenSshOptions(allocator, &args, .{
        .destination = "rove@mesh-work",
        .user_known_hosts = "UserKnownHostsFile=/tmp/known_hosts",
        .host_key_alias = "HostKeyAlias=machine-id",
        .port_option = "Port=2222",
        .identity_file = "/tmp/id_ed25519",
    }, true, true);

    try std.testing.expectEqualStrings("-F", args.items[0]);
    try std.testing.expectEqualStrings("/dev/null", args.items[1]);
}

test "wrapped remote command uses non-login shell" {
    const allocator = std.testing.allocator;
    const wrapped = try wrappedRemoteCommand(allocator, "true");
    defer allocator.free(wrapped);

    try std.testing.expectEqualStrings("/bin/bash -c 'true'", wrapped);
    try std.testing.expect(std.mem.indexOf(u8, wrapped, " -lc ") == null);
}

test "wrapped remote command preserves shell quoting" {
    const allocator = std.testing.allocator;
    const remote_command = "printf \"%s\" \"a'b\"";
    const quoted = try shell.quote(allocator, remote_command);
    defer allocator.free(quoted);
    const expected = try std.fmt.allocPrint(allocator, "/bin/bash -c {s}", .{quoted});
    defer allocator.free(expected);

    const wrapped = try wrappedRemoteCommand(allocator, remote_command);
    defer allocator.free(wrapped);

    try std.testing.expectEqualStrings(expected, wrapped);
}

test "batch command preserves multiline script exit zero" {
    const allocator = std.testing.allocator;
    const script =
        \\set -eu
        \\set +e
        \\true
        \\ledger_status=$?
        \\set -e
        \\printf "ledger_exit=%s\n" "$ledger_status"
        \\printf "final_status=clean\n"
        \\exit "$ledger_status"
    ;
    const remote_command = try std.fmt.allocPrint(allocator, "'sh' '-lc' '{s}'", .{script});
    defer allocator.free(remote_command);
    const machine = model.MachineRecord{
        .name = "work",
        .provider = .fly,
        .id = "machine-id",
        .host = "example.invalid",
        .ssh_user = "rove",
        .status = .ready,
    };
    const LocalRemoteRunner = struct {
        fn run(
            runner_allocator: std.mem.Allocator,
            argv: []const []const u8,
        ) anyerror!exec.Result {
            try std.testing.expectEqualStrings("ssh", argv[0]);
            return exec.run(runner_allocator, &.{ "/bin/sh", "-c", argv[argv.len - 1] });
        }
    };

    const result = try runBatchCommandWithRecoveryAndRunner(
        allocator,
        machine,
        remote_command,
        .{ .allow_host_key_recovery = false },
        LocalRemoteRunner.run,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.succeeded());
    try std.testing.expectEqualStrings("ledger_exit=0\nfinal_status=clean\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

fn fakeTailscaleSuccess(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) anyerror!exec.Result {
    _ = argv;
    return .{
        .term = .{ .Exited = 0 },
        .stdout = try allocator.dupe(u8, "100.64.1.2\n"),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn fakeTailscaleFailure(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) anyerror!exec.Result {
    _ = argv;
    return .{
        .term = .{ .Exited = 1 },
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, "no such host\n"),
    };
}

fn fakeReadyRunner(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) anyerror!exec.Result {
    if (argv.len >= 4 and std.mem.eql(u8, argv[0], "tailscale")) {
        return .{
            .term = .{ .Exited = 0 },
            .stdout = try allocator.dupe(u8, "100.64.1.2\n"),
            .stderr = try allocator.dupe(u8, ""),
        };
    }

    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "ssh")) {
        return .{
            .term = .{ .Exited = 0 },
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, ""),
        };
    }

    return error.UnexpectedCommand;
}

fn fakeReadinessFailureRunner(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) anyerror!exec.Result {
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "ssh")) {
        return .{
            .term = .{ .Exited = 1 },
            .stdout = try allocator.dupe(u8, "sensitive stdout\n"),
            .stderr = try allocator.dupe(u8, "sensitive stderr\n"),
        };
    }

    return fakeReadyRunner(allocator, argv);
}
