const std = @import("std");
const bootstrap = @import("bootstrap.zig");
const config = @import("config.zig");
const model = @import("model.zig");
const paths = @import("paths.zig");
const profile = @import("profile.zig");
const provider = @import("provider/mod.zig");
const sync = @import("sync.zig");
const ssh = @import("ssh.zig");
const state = @import("state.zig");
const tmux = @import("tmux.zig");
const workspace = @import("workspace.zig");

pub const ParseError = error{
    InvalidArguments,
};

pub const HandledFailure = error{
    HandledFailure,
};

pub const RunCommand = struct {
    target: []const u8,
    name: ?[]const u8 = null,
};

pub const Command = union(enum) {
    help,
    status,
    run: RunCommand,
    sync: []const u8,
    pull: []const u8,
    offload: []const u8,
    ssh: []const u8,
    down: []const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    args: []const []const u8,
) !void {
    const command = parse(args) catch |err| switch (err) {
        error.InvalidArguments => {
            try stderr.writeAll("[error] invalid arguments\n\n");
            try printHelp(stderr);
            return error.HandledFailure;
        },
        else => return err,
    };

    switch (command) {
        .help => try printHelp(stdout),
        .status => try handleStatus(allocator, stdout),
        .run => |target| try handleRun(allocator, stdout, stderr, target),
        .sync => |target| try handleSync(allocator, stdout, stderr, target),
        .pull => |target| try handlePull(allocator, stdout, stderr, target),
        .offload => |target| try handleOffload(allocator, stdout, stderr, target),
        .ssh => |target| try handleSsh(allocator, stdout, stderr, target),
        .down => |target| try handleDown(allocator, stdout, target),
    }
}

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .help;

    if (std.mem.eql(u8, args[0], "status")) {
        if (args.len != 1) return error.InvalidArguments;
        return .status;
    }

    if (std.mem.eql(u8, args[0], "run")) {
        return .{ .run = try parseRunCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "sync")) {
        return .{ .sync = try expectSingleTarget(args) };
    }

    if (std.mem.eql(u8, args[0], "pull")) {
        return .{ .pull = try expectSingleTarget(args) };
    }

    if (std.mem.eql(u8, args[0], "ssh")) {
        return .{ .ssh = try expectSingleTarget(args) };
    }

    if (std.mem.eql(u8, args[0], "offload")) {
        return .{ .offload = try expectSingleTarget(args) };
    }

    if (std.mem.eql(u8, args[0], "down")) {
        return .{ .down = try expectSingleTarget(args) };
    }

    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        if (args.len != 1) return error.InvalidArguments;
        return .help;
    }

    return error.InvalidArguments;
}

fn expectSingleTarget(args: []const []const u8) ParseError![]const u8 {
    if (args.len != 2) return error.InvalidArguments;
    if (args[1].len == 0) return error.InvalidArguments;

    return args[1];
}

fn parseRunCommand(args: []const []const u8) ParseError!RunCommand {
    if (args.len < 2) return error.InvalidArguments;
    if (args[1].len == 0) return error.InvalidArguments;

    var command = RunCommand{
        .target = args[1],
    };

    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--name")) {
            if (command.name != null) return error.InvalidArguments;
            if (index + 1 >= args.len) return error.InvalidArguments;
            if (args[index + 1].len == 0) return error.InvalidArguments;
            command.name = args[index + 1];
            index += 2;
            continue;
        }

        return error.InvalidArguments;
    }

    return command;
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\rove
        \\
        \\Usage:
        \\  rove run <target> [--name <name>]
        \\  rove sync <name>
        \\  rove pull <name>
        \\  rove offload <name>
        \\  rove status
        \\  rove ssh <name>
        \\  rove down <name>
        \\
        \\This scaffold matches the handoff's first milestone:
        \\  1. run one target on one provider
        \\  2. track it in local JSON state
        \\  3. wait for SSH and run bootstrap
        \\  4. sync a workspace and run repo-local bootstrap
        \\  5. offload a workspace into tmux
        \\  6. pull changes back
        \\  7. SSH into it
        \\  8. tear it down cleanly
        \\
        \\Defaults:
        \\  config: ./rove.json
        \\  state: ~/.rove/state.json
        \\
        \\Naming:
        \\  `run` takes a target from rove.json
        \\  `--name` chooses the tracked instance name
        \\  if omitted, the target name is used
        \\  `sync`, `pull`, `offload`, `ssh`, and `down` address the tracked instance name
        \\
    );
}

fn handleStatus(
    allocator: std.mem.Allocator,
    stdout: anytype,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    if (loaded_state.value.machines.len == 0) {
        try stdout.writeAll(
            "[info] no tracked machines\n" ++
                "[hint] new machines will be recorded in ~/.rove/state.json after `rove run <target>` succeeds\n",
        );
        return;
    }

    try stdout.writeAll("NAME\tTARGET\tPROVIDER\tSTATUS\tHOST\tWORKSPACE\n");
    for (loaded_state.value.machines) |machine| {
        const workspace_path = if (machine.workspace) |workspace_record|
            workspace_record.remote_path
        else
            "-";
        const target_name = machine.target_name orelse machine.name;
        try std.fmt.format(
            stdout,
            "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
            .{
                machine.name,
                target_name,
                model.providerName(machine.provider),
                model.statusName(machine.status),
                machine.host,
                workspace_path,
            },
        );
    }
}

fn handleRun(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: RunCommand,
) !void {
    const instance_name = command.name orelse command.target;
    if (!isValidInstanceName(instance_name)) {
        try std.fmt.format(
            stderr,
            "[error] invalid instance name '{s}'\n" ++
                "[hint] use letters, digits, '-', '_' or '.'\n",
            .{instance_name},
        );
        return error.HandledFailure;
    }

    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    if (state.findMachine(&loaded_state.value, instance_name) != null) {
        try std.fmt.format(
            stderr,
            "[error] instance '{s}' already has a tracked machine\n" ++
                "[hint] use `rove status` to inspect it or `rove down {s}` before creating another\n",
            .{ instance_name, instance_name },
        );
        return error.HandledFailure;
    }

    var loaded_config = config.load(allocator, null) catch |err| switch (err) {
        error.FileNotFound => {
            try std.fmt.format(
                stderr,
                "[error] missing config file '{s}'\n" ++
                    "[hint] create it before running a target\n",
                .{paths.defaultConfigPath()},
            );
            return error.HandledFailure;
        },
        else => return err,
    };
    defer loaded_config.deinit();

    const target = config.resolveTarget(&loaded_config.value, command.target) catch |err| switch (err) {
        error.TargetNotFound => {
            try std.fmt.format(
                stderr,
                "[error] unknown target '{s}'\n" ++
                    "[hint] add it to {s}\n",
                .{ command.target, paths.defaultConfigPath() },
            );
            return error.HandledFailure;
        },
        else => return err,
    };

    const placement = try renderPlacementSummary(allocator, target.*);
    defer allocator.free(placement);

    const created = provider.create(allocator, target.provider, .{
        .target = target,
        .instance_name = instance_name,
    }) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to create target '{s}' via {s}: {s}\n",
            .{ target.name, model.providerName(target.provider), @errorName(err) },
        );
        return error.HandledFailure;
    };
    defer created.deinit(allocator);

    var machine = model.MachineRecord{
        .name = instance_name,
        .target_name = target.name,
        .provider = target.provider,
        .id = created.machine_id,
        .machine_name = created.machine_name,
        .app = target.app,
        .host = created.host,
        .region = created.region,
        .ssh_user = target.ssh_user,
        .status = .provisioned,
    };

    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] instance '{s}' created from target '{s}'\n" ++
            "[info] target: {s}\n" ++
            "[info] name: {s}\n" ++
            "[info] provider: {s}\n" ++
            "[info] app: {s}\n" ++
            "[info] machine_id: {s}\n" ++
            "[info] image: {s}\n" ++
            "[info] vm_size: {s}\n" ++
            "[info] placement: {s}\n" ++
            "[info] host: {s}\n",
        .{
            machine.name,
            target.name,
            target.name,
            machine.name,
            model.providerName(target.provider),
            target.app,
            created.machine_id,
            target.image,
            target.vm_size,
            placement,
            created.host,
        },
    );

    machine.status = .waiting_for_ssh;
    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] waiting for SSH on {s}@{s}\n",
        .{ machine.ssh_user, machine.host },
    );

    ssh.waitForReady(allocator, machine, .{}) catch |err| {
        machine.status = .provisioned_unreachable;
        try state.upsertMachine(allocator, machine, null);

        try std.fmt.format(
            stderr,
            "[error] ssh did not become ready for instance '{s}': {s}\n" ++
                "[hint] inspect the machine with `rove status` or `rove ssh {s}` once access works\n",
            .{ machine.name, @errorName(err), machine.name },
        );
        return error.HandledFailure;
    };

    machine.status = .bootstrapping;
    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] SSH ready\n" ++
            "[info] running bootstrap script: {s}\n",
        .{target.startup_script},
    );

    bootstrap.run(allocator, machine, target.startup_script) catch |err| {
        machine.status = .bootstrap_failed;
        try state.upsertMachine(allocator, machine, null);

        try std.fmt.format(
            stderr,
            "[error] bootstrap failed for instance '{s}': {s}\n" ++
                "[hint] the machine is still running; use `rove ssh {s}` to inspect it\n",
            .{ machine.name, @errorName(err), machine.name },
        );
        return error.HandledFailure;
    };

    if (target.profile) |target_profile| {
        machine.status = .applying_profile;
        try state.upsertMachine(allocator, machine, null);

        try std.fmt.format(
            stdout,
            "[info] applying profile: {s}\n",
            .{target_profile.repo},
        );

        profile.apply(allocator, machine, target_profile) catch |err| {
            machine.status = .profile_failed;
            try state.upsertMachine(allocator, machine, null);

            try std.fmt.format(
                stderr,
                "[error] profile apply failed for instance '{s}': {s}\n" ++
                    "[hint] the machine is still running; use `rove ssh {s}` to inspect it\n",
                .{ machine.name, @errorName(err), machine.name },
            );
            return error.HandledFailure;
        };

        // Re-run the base bootstrap after profile install so Rove-managed shell setup survives dotfiles changes.
        bootstrap.run(allocator, machine, target.startup_script) catch |err| {
            machine.status = .profile_failed;
            try state.upsertMachine(allocator, machine, null);

            try std.fmt.format(
                stderr,
                "[error] failed to reconcile bootstrap after profile apply for instance '{s}': {s}\n" ++
                    "[hint] the machine is still running; use `rove ssh {s}` to inspect it\n",
                .{ machine.name, @errorName(err), machine.name },
            );
            return error.HandledFailure;
        };
    }

    machine.status = .ready;
    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] instance '{s}' is ready\n" ++
            "[hint] connect with `rove ssh {s}`\n",
        .{ machine.name, machine.name },
    );
}

fn handleSsh(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    target_name: []const u8,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine = state.findMachine(&loaded_state.value, target_name) orelse {
        try std.fmt.format(
            stdout,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so SSH knows where to connect\n",
            .{target_name},
        );
        return error.HandledFailure;
    };

    if (machine.status == .destroying) {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' is being destroyed\n",
            .{target_name},
        );
        return error.HandledFailure;
    }

    const term = ssh.openInteractive(allocator, machine.*) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to start ssh for machine '{s}': {s}\n",
            .{ target_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                try std.fmt.format(
                    stderr,
                    "[error] ssh exited with code {d}\n",
                    .{code},
                );
                return error.HandledFailure;
            }
        },
        else => {
            try stderr.writeAll("[error] ssh ended unexpectedly\n");
            return error.HandledFailure;
        },
    }
}

fn handleSync(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    machine_name: []const u8,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine_ptr = state.findMachine(&loaded_state.value, machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so there is a machine to sync into\n",
            .{machine_name},
        );
        return error.HandledFailure;
    };

    if (machine_ptr.status == .destroying) {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' is being destroyed\n",
            .{machine_name},
        );
        return error.HandledFailure;
    }

    var machine = machine_ptr.*;
    const resolved = try workspace.discover(allocator, machine.workspace);
    defer resolved.deinit(allocator);

    try std.fmt.format(
        stdout,
        "[info] syncing workspace '{s}' to {s}\n",
        .{ resolved.local_root, resolved.remote_root },
    );

    const ran_bootstrap_hook = try syncResolvedWorkspace(
        allocator,
        stderr,
        &machine,
        machine_name,
        resolved,
        .syncing,
        .sync_failed,
    );

    machine.workspace = mergedWorkspaceRecord(machine, resolved, null);
    machine.status = .ready;
    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] workspace synced for machine '{s}'\n",
        .{machine_name},
    );
    if (ran_bootstrap_hook) {
        try stdout.writeAll("[info] ran repo-local bootstrap hook .rove/bootstrap.sh\n");
    }
}

fn handlePull(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    machine_name: []const u8,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine_ptr = state.findMachine(&loaded_state.value, machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so there is a machine to pull from\n",
            .{machine_name},
        );
        return error.HandledFailure;
    };

    if (machine_ptr.status == .destroying) {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' is being destroyed\n",
            .{machine_name},
        );
        return error.HandledFailure;
    }

    const tracked_workspace = machine_ptr.workspace orelse {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' has no tracked workspace yet\n" ++
                "[hint] run `rove sync {s}` or `rove offload {s}` first\n",
            .{ machine_name, machine_name, machine_name },
        );
        return error.HandledFailure;
    };

    var machine = machine_ptr.*;
    const resolved = try workspace.fromRecord(allocator, tracked_workspace);
    defer resolved.deinit(allocator);

    machine.status = .pulling;
    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] pulling workspace from {s} to '{s}'\n",
        .{ resolved.remote_root, resolved.local_root },
    );

    sync.pullWorkspaceFiles(allocator, machine, resolved) catch |err| {
        machine.status = .pull_failed;
        try state.upsertMachine(allocator, machine, null);

        try std.fmt.format(
            stderr,
            "[error] workspace pull failed for machine '{s}': {s}\n",
            .{ machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    machine.status = .ready;
    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] workspace pulled for machine '{s}'\n",
        .{machine_name},
    );
}

fn handleOffload(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    target_name: []const u8,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine_ptr = state.findMachine(&loaded_state.value, target_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so there is a machine to offload into\n",
            .{target_name},
        );
        return error.HandledFailure;
    };

    if (machine_ptr.status == .destroying) {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' is being destroyed\n",
            .{target_name},
        );
        return error.HandledFailure;
    }

    var machine = machine_ptr.*;
    const resolved = try workspace.discover(allocator, machine.workspace);
    defer resolved.deinit(allocator);

    var loaded_config: ?std.json.Parsed(model.ConfigFile) = config.load(allocator, null) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (loaded_config) |*parsed| parsed.deinit();

    const planned = planned: {
        if (loaded_config) |*parsed| {
            const config_target_name = machine.target_name orelse machine.name;
            const target = config.resolveTarget(&parsed.value, config_target_name) catch |err| switch (err) {
                error.TargetNotFound => break :planned try tmux.planOffload(allocator, .{}, resolved),
                else => return err,
            };
            break :planned try tmux.planOffload(allocator, target.tmux, resolved);
        }

        break :planned try tmux.planOffload(allocator, .{}, resolved);
    };
    defer planned.deinit(allocator);

    machine.status = .offloading;
    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] syncing workspace '{s}' to {s}\n" ++
            "[info] tmux backend: {s}\n" ++
            "[info] restoring tmux session '{s}'\n",
        .{ resolved.local_root, resolved.remote_root, tmux.backendName(planned.backend), planned.restore.session_name },
    );

    const ran_bootstrap_hook = try syncResolvedWorkspace(
        allocator,
        stderr,
        &machine,
        target_name,
        resolved,
        .offloading,
        .offload_failed,
    );

    tmux.applyRemote(allocator, machine, planned.restore) catch |err| {
        machine.status = .offload_failed;
        try state.upsertMachine(allocator, machine, null);

        try std.fmt.format(
            stderr,
            "[error] tmux restore failed for machine '{s}': {s}\n",
            .{ target_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    machine.workspace = mergedWorkspaceRecord(machine, resolved, planned.restore.session_name);
    machine.status = .ready;
    try state.upsertMachine(allocator, machine, null);

    if (ran_bootstrap_hook) {
        try stdout.writeAll("[info] ran repo-local bootstrap hook .rove/bootstrap.sh\n");
    }

    const attach_command = try tmux.attachCommand(allocator, planned.restore);
    defer allocator.free(attach_command);

    const term = ssh.openInteractiveCommand(allocator, machine, attach_command) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to attach remote tmux for machine '{s}': {s}\n",
            .{ target_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                try std.fmt.format(
                    stderr,
                    "[error] remote tmux attach exited with code {d}\n",
                    .{code},
                );
                return error.HandledFailure;
            }
        },
        else => {
            try stderr.writeAll("[error] remote tmux attach ended unexpectedly\n");
            return error.HandledFailure;
        },
    }
}

fn handleDown(
    allocator: std.mem.Allocator,
    stdout: anytype,
    target_name: []const u8,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine = state.findMachine(&loaded_state.value, target_name) orelse {
        try std.fmt.format(
            stdout,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] nothing to destroy until a machine has been run at least once\n",
            .{target_name},
        );
        return error.HandledFailure;
    };

    var destroying = machine.*;
    destroying.status = .destroying;
    try state.upsertMachine(allocator, destroying, null);

    provider.destroy(allocator, machine.provider, .{
        .app = machine.app orelse {
            try std.fmt.format(
                stdout,
                "[error] tracked machine '{s}' is missing app metadata\n",
                .{target_name},
            );
            return error.HandledFailure;
        },
        .machine_id = machine.id,
    }) catch |err| {
        try std.fmt.format(
            stdout,
            "[error] failed to destroy machine '{s}': {s}\n",
            .{ target_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    _ = try state.removeMachine(allocator, target_name, null);

    try std.fmt.format(
        stdout,
        "[info] machine '{s}' destroyed\n" ++
            "[info] machine_id: {s}\n" ++
            "[hint] local state has been cleared\n",
        .{ target_name, machine.id },
    );
}

fn renderPlacementSummary(
    allocator: std.mem.Allocator,
    target: model.TargetConfig,
) ![]u8 {
    if (target.region) |region| {
        return std.fmt.allocPrint(allocator, "fixed region {s}", .{region});
    }

    if (target.region_preference) |preference| {
        const joined = try std.mem.join(allocator, ",", preference);
        defer allocator.free(joined);

        return std.fmt.allocPrint(allocator, "flexible preference {s}", .{joined});
    }

    return allocator.dupe(u8, "runtime-selected region");
}

fn syncResolvedWorkspace(
    allocator: std.mem.Allocator,
    stderr: anytype,
    machine: *model.MachineRecord,
    machine_name: []const u8,
    resolved: workspace.ResolvedWorkspace,
    active_status: model.LifecycleStatus,
    failure_status: model.LifecycleStatus,
) !bool {
    machine.status = active_status;
    try state.upsertMachine(allocator, machine.*, null);

    const result = sync.syncWorkspace(allocator, machine.*, resolved) catch |err| {
        machine.status = failure_status;
        try state.upsertMachine(allocator, machine.*, null);

        try std.fmt.format(
            stderr,
            "[error] workspace sync failed for machine '{s}': {s}\n",
            .{ machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    return result.ran_bootstrap_hook;
}

fn mergedWorkspaceRecord(
    machine: model.MachineRecord,
    resolved: workspace.ResolvedWorkspace,
    tmux_session: ?[]const u8,
) model.WorkspaceRecord {
    return .{
        .local_path = resolved.local_root,
        .remote_path = resolved.remote_root,
        .tmux_session = if (tmux_session) |session|
            session
        else if (machine.workspace) |existing|
            existing.tmux_session
        else
            null,
    };
}

fn isValidInstanceName(name: []const u8) bool {
    if (name.len == 0) return false;

    for (name) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.') continue;
        return false;
    }

    return true;
}

test "parse status" {
    const command = try parse(&.{"status"});

    switch (command) {
        .status => {},
        else => return error.InvalidArguments,
    }
}

test "parse run target" {
    const command = try parse(&.{ "run", "gpu" });

    switch (command) {
        .run => |run_command| {
            try std.testing.expectEqualStrings("gpu", run_command.target);
            try std.testing.expect(run_command.name == null);
        },
        else => return error.InvalidArguments,
    }
}

test "parse run target with explicit name" {
    const command = try parse(&.{ "run", "devbox", "--name", "sam-east" });

    switch (command) {
        .run => |run_command| {
            try std.testing.expectEqualStrings("devbox", run_command.target);
            try std.testing.expectEqualStrings("sam-east", run_command.name.?);
        },
        else => return error.InvalidArguments,
    }
}

test "parse sync target" {
    const command = try parse(&.{ "sync", "sam-east" });

    switch (command) {
        .sync => |name| try std.testing.expectEqualStrings("sam-east", name),
        else => return error.InvalidArguments,
    }
}

test "parse pull target" {
    const command = try parse(&.{ "pull", "sam-east" });

    switch (command) {
        .pull => |name| try std.testing.expectEqualStrings("sam-east", name),
        else => return error.InvalidArguments,
    }
}

test "reject missing target" {
    try std.testing.expectError(error.InvalidArguments, parse(&.{"ssh"}));
}

test "reject run name without value" {
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "run", "devbox", "--name" }));
}

test "reject unknown command" {
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "launch", "gpu" }));
}
