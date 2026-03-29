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

pub const Command = union(enum) {
    help,
    status,
    run: []const u8,
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
        return .{ .run = try expectSingleTarget(args) };
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

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\rove
        \\
        \\Usage:
        \\  rove run <target>
        \\  rove offload <target>
        \\  rove status
        \\  rove ssh <target>
        \\  rove down <target>
        \\
        \\This scaffold matches the handoff's first milestone:
        \\  1. run one target on one provider
        \\  2. track it in local JSON state
        \\  3. wait for SSH and run bootstrap
        \\  4. offload a workspace into tmux
        \\  5. SSH into it
        \\  6. tear it down cleanly
        \\
        \\Defaults:
        \\  config: ./rove.json
        \\  state: ~/.rove/state.json
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

    try stdout.writeAll("NAME\tPROVIDER\tSTATUS\tHOST\tWORKSPACE\n");
    for (loaded_state.value.machines) |machine| {
        const workspace_path = if (machine.workspace) |workspace_record|
            workspace_record.remote_path
        else
            "-";
        try std.fmt.format(
            stdout,
            "{s}\t{s}\t{s}\t{s}\t{s}\n",
            .{
                machine.name,
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
    target_name: []const u8,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    if (state.findMachine(&loaded_state.value, target_name) != null) {
        try std.fmt.format(
            stderr,
            "[error] target '{s}' already has a tracked machine\n" ++
                "[hint] use `rove status` to inspect it or `rove down {s}` before creating another\n",
            .{ target_name, target_name },
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

    const target = config.resolveTarget(&loaded_config.value, target_name) catch |err| switch (err) {
        error.TargetNotFound => {
            try std.fmt.format(
                stderr,
                "[error] unknown target '{s}'\n" ++
                    "[hint] add it to {s}\n",
                .{ target_name, paths.defaultConfigPath() },
            );
            return error.HandledFailure;
        },
        else => return err,
    };

    const placement = try renderPlacementSummary(allocator, target.*);
    defer allocator.free(placement);

    const created = provider.create(allocator, target.provider, .{
        .target = target,
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
        .name = target.name,
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
        "[info] target '{s}' created\n" ++
            "[info] provider: {s}\n" ++
            "[info] app: {s}\n" ++
            "[info] machine_id: {s}\n" ++
            "[info] image: {s}\n" ++
            "[info] vm_size: {s}\n" ++
            "[info] placement: {s}\n" ++
            "[info] host: {s}\n",
        .{
            target.name,
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
            "[error] ssh did not become ready for target '{s}': {s}\n" ++
                "[hint] inspect the machine with `rove status` or `rove ssh {s}` once access works\n",
            .{ target.name, @errorName(err), target.name },
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
            "[error] bootstrap failed for target '{s}': {s}\n" ++
                "[hint] the machine is still running; use `rove ssh {s}` to inspect it\n",
            .{ target.name, @errorName(err), target.name },
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
                "[error] profile apply failed for target '{s}': {s}\n" ++
                    "[hint] the machine is still running; use `rove ssh {s}` to inspect it\n",
                .{ target.name, @errorName(err), target.name },
            );
            return error.HandledFailure;
        };

        // Re-run the base bootstrap after profile install so Rove-managed shell setup survives dotfiles changes.
        bootstrap.run(allocator, machine, target.startup_script) catch |err| {
            machine.status = .profile_failed;
            try state.upsertMachine(allocator, machine, null);

            try std.fmt.format(
                stderr,
                "[error] failed to reconcile bootstrap after profile apply for target '{s}': {s}\n" ++
                    "[hint] the machine is still running; use `rove ssh {s}` to inspect it\n",
                .{ target.name, @errorName(err), target.name },
            );
            return error.HandledFailure;
        };
    }

    machine.status = .ready;
    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] target '{s}' is ready\n" ++
            "[hint] connect with `rove ssh {s}`\n",
        .{ target.name, target.name },
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
            "[error] no tracked machine for target '{s}'\n" ++
                "[hint] run the target first so SSH knows where to connect\n",
            .{target_name},
        );
        return error.HandledFailure;
    };

    if (machine.status == .destroying) {
        try std.fmt.format(
            stderr,
            "[error] target '{s}' is being destroyed\n",
            .{target_name},
        );
        return error.HandledFailure;
    }

    const term = ssh.openInteractive(allocator, machine.*) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to start ssh for target '{s}': {s}\n",
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
            "[error] no tracked machine for target '{s}'\n" ++
                "[hint] run the target first so there is a machine to offload into\n",
            .{target_name},
        );
        return error.HandledFailure;
    };

    if (machine_ptr.status == .destroying) {
        try std.fmt.format(
            stderr,
            "[error] target '{s}' is being destroyed\n",
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
            const target = config.resolveTarget(&parsed.value, target_name) catch |err| switch (err) {
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

    sync.pushWorkspace(allocator, machine, resolved) catch |err| {
        machine.status = .offload_failed;
        try state.upsertMachine(allocator, machine, null);

        try std.fmt.format(
            stderr,
            "[error] workspace sync failed for target '{s}': {s}\n",
            .{ target_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    tmux.applyRemote(allocator, machine, planned.restore) catch |err| {
        machine.status = .offload_failed;
        try state.upsertMachine(allocator, machine, null);

        try std.fmt.format(
            stderr,
            "[error] tmux restore failed for target '{s}': {s}\n",
            .{ target_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    const workspace_record = model.WorkspaceRecord{
        .local_path = resolved.local_root,
        .remote_path = resolved.remote_root,
        .tmux_session = planned.restore.session_name,
    };
    machine.workspace = workspace_record;
    machine.status = .ready;
    try state.upsertMachine(allocator, machine, null);

    const attach_command = try tmux.attachCommand(allocator, planned.restore);
    defer allocator.free(attach_command);

    const term = ssh.openInteractiveCommand(allocator, machine, attach_command) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to attach remote tmux for target '{s}': {s}\n",
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
            "[error] no tracked machine for target '{s}'\n" ++
                "[hint] nothing to destroy until the target has been run at least once\n",
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
                "[error] tracked machine for '{s}' is missing app metadata\n",
                .{target_name},
            );
            return error.HandledFailure;
        },
        .machine_id = machine.id,
    }) catch |err| {
        try std.fmt.format(
            stdout,
            "[error] failed to destroy target '{s}': {s}\n",
            .{ target_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    _ = try state.removeMachine(allocator, target_name, null);

    try std.fmt.format(
        stdout,
        "[info] target '{s}' destroyed\n" ++
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
        .run => |target| try std.testing.expectEqualStrings("gpu", target),
        else => return error.InvalidArguments,
    }
}

test "reject missing target" {
    try std.testing.expectError(error.InvalidArguments, parse(&.{"ssh"}));
}

test "reject unknown command" {
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "launch", "gpu" }));
}
