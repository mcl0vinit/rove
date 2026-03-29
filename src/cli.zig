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

pub const PullCommand = struct {
    machine_name: []const u8,
    preview: bool = false,
    force: bool = false,
    workspace_selector: ?[]const u8 = null,
};

pub const WorkspaceTargetCommand = struct {
    machine_name: []const u8,
    workspace_selector: ?[]const u8 = null,
};

pub const Command = union(enum) {
    help,
    status,
    run: RunCommand,
    sync: []const u8,
    pull: PullCommand,
    workspaces: []const u8,
    offload: WorkspaceTargetCommand,
    ssh: WorkspaceTargetCommand,
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
        .status => try handleStatus(allocator, stdout, stderr),
        .run => |target| try handleRun(allocator, stdout, stderr, target),
        .sync => |target| try handleSync(allocator, stdout, stderr, target),
        .pull => |pull_command| try handlePull(allocator, stdout, stderr, pull_command),
        .workspaces => |machine_name| try handleWorkspaces(allocator, stdout, stderr, machine_name),
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
        return .{ .pull = try parsePullCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "workspaces")) {
        return .{ .workspaces = try expectSingleTarget(args) };
    }

    if (std.mem.eql(u8, args[0], "ssh")) {
        return .{ .ssh = try parseWorkspaceTargetCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "offload")) {
        return .{ .offload = try parseWorkspaceTargetCommand(args) };
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

fn parsePullCommand(args: []const []const u8) ParseError!PullCommand {
    if (args.len < 2) return error.InvalidArguments;
    if (args[1].len == 0) return error.InvalidArguments;

    var command = PullCommand{
        .machine_name = args[1],
    };

    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--preview")) {
            if (command.preview) return error.InvalidArguments;
            command.preview = true;
            index += 1;
            continue;
        }

        if (std.mem.eql(u8, args[index], "--force")) {
            if (command.force) return error.InvalidArguments;
            command.force = true;
            index += 1;
            continue;
        }

        if (std.mem.eql(u8, args[index], "--workspace")) {
            if (command.workspace_selector != null) return error.InvalidArguments;
            if (index + 1 >= args.len) return error.InvalidArguments;
            if (args[index + 1].len == 0) return error.InvalidArguments;
            command.workspace_selector = args[index + 1];
            index += 2;
            continue;
        }

        return error.InvalidArguments;
    }

    return command;
}

fn parseWorkspaceTargetCommand(args: []const []const u8) ParseError!WorkspaceTargetCommand {
    if (args.len < 2) return error.InvalidArguments;
    if (args[1].len == 0) return error.InvalidArguments;

    var command = WorkspaceTargetCommand{
        .machine_name = args[1],
    };

    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--workspace")) {
            if (command.workspace_selector != null) return error.InvalidArguments;
            if (index + 1 >= args.len) return error.InvalidArguments;
            if (args[index + 1].len == 0) return error.InvalidArguments;
            command.workspace_selector = args[index + 1];
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
        \\  rove pull <name> [--workspace <label-or-path>] [--preview] [--force]
        \\  rove workspaces <name>
        \\  rove offload <name> [--workspace <label-or-path>]
        \\  rove status
        \\  rove ssh <name> [--workspace <label-or-path>]
        \\  rove down <name>
        \\
        \\This scaffold matches the handoff's first milestone:
        \\  1. run one target on one provider
        \\  2. track it in local JSON state
        \\  3. wait for SSH and run bootstrap
        \\  4. sync a workspace and run repo-local bootstrap
        \\  5. offload a workspace into tmux
        \\  6. pull changes back
        \\  7. inspect tracked workspaces
        \\  8. SSH into it
        \\  9. tear it down cleanly
        \\
        \\Defaults:
        \\  config: ./rove.json
        \\  state: ~/.rove/state.json
        \\
        \\Naming:
        \\  `run` takes a target from rove.json
        \\  `--name` chooses the tracked instance name
        \\  if omitted, the target name is used
        \\  `sync`, `pull`, `workspaces`, `offload`, `ssh`, and `down` address the tracked instance name
        \\  `pull --workspace` selects one tracked workspace by label, local path, or remote path
        \\  `ssh --workspace` and `offload --workspace` reuse a specific tracked workspace
        \\  `pull --preview` shows rsync changes without writing local files
        \\  `pull` refuses to overwrite a dirty local git repo unless `--force` is set
        \\
    );
}

fn handleStatus(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
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

    try stdout.writeAll("NAME\tTARGET\tPROVIDER\tSTATUS\tREMOTE\tHOST\tWORKSPACE\n");
    for (loaded_state.value.machines) |machine| {
        var refreshed = refreshMachineFromProvider(allocator, machine) catch |err| fallback: {
            try std.fmt.format(
                stderr,
                "[warn] failed to refresh machine '{s}': {s}\n",
                .{ machine.name, @errorName(err) },
            );

            var fallback = RefreshedMachine{
                .value = machine,
            };
            fallback.value.remote_state = "refresh_failed";
            break :fallback fallback;
        };
        defer refreshed.deinit(allocator);

        try state.upsertMachine(allocator, refreshed.value, null);

        const target_name = refreshed.value.target_name orelse refreshed.value.name;
        const remote_state = refreshed.value.remote_state orelse "-";
        if (workspace.activeTracked(refreshed.value)) |tracked_workspace| {
            const tracked_count = workspace.trackedCount(refreshed.value);
            if (tracked_count > 1) {
                try std.fmt.format(
                    stdout,
                    "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s} (+{d})\n",
                    .{
                        refreshed.value.name,
                        target_name,
                        model.providerName(refreshed.value.provider),
                        model.statusName(refreshed.value.status),
                        remote_state,
                        refreshed.value.host,
                        tracked_workspace.remote_path,
                        tracked_count - 1,
                    },
                );
            } else {
                try std.fmt.format(
                    stdout,
                    "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
                    .{
                        refreshed.value.name,
                        target_name,
                        model.providerName(refreshed.value.provider),
                        model.statusName(refreshed.value.status),
                        remote_state,
                        refreshed.value.host,
                        tracked_workspace.remote_path,
                    },
                );
            }
        } else {
            try std.fmt.format(
                stdout,
                "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t-\n",
                .{
                    refreshed.value.name,
                    target_name,
                    model.providerName(refreshed.value.provider),
                    model.statusName(refreshed.value.status),
                    remote_state,
                    refreshed.value.host,
                },
            );
        }
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
    command: WorkspaceTargetCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine = state.findMachine(&loaded_state.value, command.machine_name) orelse {
        try std.fmt.format(
            stdout,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so SSH knows where to connect\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    };

    if (machine.status == .destroying) {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' is being destroyed\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    }

    const term = if (command.workspace_selector) |selector|
        try openWorkspaceSsh(allocator, stderr, machine.*, command.machine_name, selector)
    else
        ssh.openInteractive(allocator, machine.*) catch |err| {
            try std.fmt.format(
                stderr,
                "[error] failed to start ssh for machine '{s}': {s}\n",
                .{ command.machine_name, @errorName(err) },
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

fn handleWorkspaces(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    machine_name: []const u8,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine = state.findMachine(&loaded_state.value, machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so there is a machine to inspect\n",
            .{machine_name},
        );
        return error.HandledFailure;
    };

    if (workspace.trackedCount(machine.*) == 0) {
        try std.fmt.format(
            stdout,
            "[info] machine '{s}' has no tracked workspaces yet\n" ++
                "[hint] run `rove sync {s}` or `rove offload {s}` first\n",
            .{ machine_name, machine_name, machine_name },
        );
        return;
    }

    const active = workspace.activeTracked(machine.*);
    try stdout.writeAll("ACTIVE\tNAME\tLOCAL\tREMOTE\tTMUX\n");

    if (machine.workspaces.len > 0) {
        for (machine.workspaces) |tracked| {
            try printWorkspaceRow(stdout, tracked, active);
        }
    } else if (machine.workspace) |tracked| {
        try printWorkspaceRow(stdout, tracked, active);
    }
}

fn printWorkspaceRow(
    stdout: anytype,
    tracked: model.WorkspaceRecord,
    active: ?model.WorkspaceRecord,
) !void {
    const is_active = if (active) |record|
        std.mem.eql(u8, record.local_path, tracked.local_path)
    else
        false;
    const tmux_session = tracked.tmux_session orelse "-";

    try std.fmt.format(
        stdout,
        "{s}\t{s}\t{s}\t{s}\t{s}\n",
        .{
            if (is_active) "*" else "-",
            workspace.recordName(tracked),
            tracked.local_path,
            tracked.remote_path,
            tmux_session,
        },
    );
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
    const resolved = try workspace.discover(allocator, machine);
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

    const tracked_workspaces = try workspace.mergeTracked(allocator, machine, workspace.buildRecord(resolved, null));
    defer tracked_workspaces.deinit(allocator);

    machine.workspace = tracked_workspaces.active;
    machine.workspaces = tracked_workspaces.records;
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
    command: PullCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine_ptr = state.findMachine(&loaded_state.value, command.machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so there is a machine to pull from\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    };

    if (machine_ptr.status == .destroying) {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' is being destroyed\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    }

    var machine = machine_ptr.*;
    const resolved = workspace.resolvePull(allocator, machine, command.workspace_selector) catch |err| switch (err) {
        error.WorkspaceNotFound => {
            try std.fmt.format(
                stderr,
                "[error] machine '{s}' has no tracked workspace matching '{s}'\n" ++
                    "[hint] use the workspace label, local path, or remote path from `rove workspaces {s}`\n",
                .{ command.machine_name, command.workspace_selector.?, command.machine_name },
            );
            return error.HandledFailure;
        },
        error.AmbiguousWorkspaceSelector => {
            try std.fmt.format(
                stderr,
                "[error] workspace selector '{s}' is ambiguous for machine '{s}'\n" ++
                    "[hint] use the full local path or remote path to disambiguate\n",
                .{ command.workspace_selector.?, command.machine_name },
            );
            return error.HandledFailure;
        },
        error.NoTrackedWorkspace => {
            try std.fmt.format(
                stderr,
                "[error] machine '{s}' has no tracked workspace yet\n" ++
                    "[hint] run `rove sync {s}` or `rove offload {s}` first\n",
                .{ command.machine_name, command.machine_name, command.machine_name },
            );
            return error.HandledFailure;
        },
        else => return err,
    };
    defer resolved.deinit(allocator);

    var preview = sync.previewPullWorkspace(allocator, machine, resolved) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] workspace pull preview failed for machine '{s}': {s}\n",
            .{ command.machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };
    defer preview.deinit(allocator);
    const has_changes = preview.hasChanges();

    if (command.preview) {
        try std.fmt.format(
            stdout,
            "[info] previewing pull from {s} to '{s}'\n",
            .{ resolved.remote_root, resolved.local_root },
        );

        if (has_changes) {
            try stdout.writeAll(preview.changes);
        } else {
            try stdout.writeAll("[info] no remote changes detected\n");
        }
        return;
    }

    const local_dirty = try workspace.localRepoHasUncommittedChanges(allocator, resolved.local_root);
    if (local_dirty and has_changes and !command.force) {
        try std.fmt.format(
            stderr,
            "[error] local workspace '{s}' has uncommitted git changes\n" ++
                "[hint] run `rove pull {s} --preview` to inspect remote changes or `rove pull {s} --force` to continue\n",
            .{ resolved.local_root, command.machine_name, command.machine_name },
        );
        return error.HandledFailure;
    }

    if (has_changes) {
        try std.fmt.format(
            stdout,
            "[info] pulling workspace from {s} to '{s}'\n",
            .{ resolved.remote_root, resolved.local_root },
        );
        if (local_dirty and command.force) {
            try stdout.writeAll("[info] local git repo is dirty; continuing because --force was set\n");
        }
    } else {
        try stdout.writeAll("[info] no remote changes detected\n");
    }

    const tracked_workspaces = try workspace.mergeTracked(allocator, machine, workspace.buildRecord(resolved, null));
    defer tracked_workspaces.deinit(allocator);

    if (has_changes) {
        machine.status = .pulling;
        try state.upsertMachine(allocator, machine, null);

        sync.pullWorkspaceFiles(allocator, machine, resolved) catch |err| {
            machine.status = .pull_failed;
            try state.upsertMachine(allocator, machine, null);

            try std.fmt.format(
                stderr,
                "[error] workspace pull failed for machine '{s}': {s}\n",
                .{ command.machine_name, @errorName(err) },
            );
            return error.HandledFailure;
        };
    }

    machine.workspace = tracked_workspaces.active;
    machine.workspaces = tracked_workspaces.records;
    machine.status = .ready;
    try state.upsertMachine(allocator, machine, null);

    if (has_changes) {
        try std.fmt.format(
            stdout,
            "[info] workspace pulled for machine '{s}'\n",
            .{command.machine_name},
        );
    } else {
        try std.fmt.format(
            stdout,
            "[info] workspace already up to date for machine '{s}'\n",
            .{command.machine_name},
        );
    }
}

fn handleOffload(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: WorkspaceTargetCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine_ptr = state.findMachine(&loaded_state.value, command.machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so there is a machine to offload into\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    };

    if (machine_ptr.status == .destroying) {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' is being destroyed\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    }

    var machine = machine_ptr.*;
    if (command.workspace_selector) |selector| {
        const tracked = try resolveTrackedWorkspaceRecord(stderr, machine, command.machine_name, selector);
        const resolved = try workspace.fromRecord(allocator, tracked);
        defer resolved.deinit(allocator);

        const planned = tmux.PlannedRestore{
            .backend = .tracked,
            .restore = try tmux.planTrackedWorkspaceSession(allocator, resolved, tracked.tmux_session),
        };
        defer planned.deinit(allocator);

        try performOffload(allocator, stdout, stderr, &machine, command.machine_name, resolved, planned);
        return;
    }

    const resolved = try workspace.discover(allocator, machine);
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

    try performOffload(allocator, stdout, stderr, &machine, command.machine_name, resolved, planned);
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

const RefreshedMachine = struct {
    value: model.MachineRecord,
    owned_machine_name: ?[]const u8 = null,
    owned_host: ?[]const u8 = null,
    owned_region: ?[]const u8 = null,
    owned_remote_state: ?[]const u8 = null,

    fn deinit(self: RefreshedMachine, allocator: std.mem.Allocator) void {
        if (self.owned_machine_name) |machine_name| allocator.free(machine_name);
        if (self.owned_host) |host| allocator.free(host);
        if (self.owned_region) |region| allocator.free(region);
        if (self.owned_remote_state) |remote_state| allocator.free(remote_state);
    }
};

fn refreshMachineFromProvider(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !RefreshedMachine {
    var refreshed = RefreshedMachine{
        .value = machine,
    };

    const app = machine.app orelse {
        refreshed.value.remote_state = "unknown";
        return refreshed;
    };

    const inspected = try provider.inspect(allocator, machine.provider, .{
        .app = app,
        .machine_id = machine.id,
    });

    if (!inspected.exists) {
        refreshed.value.remote_state = "missing";
        return refreshed;
    }

    if (inspected.machine_name) |machine_name| {
        refreshed.value.machine_name = machine_name;
        refreshed.owned_machine_name = machine_name;
    }
    if (inspected.host) |host| {
        refreshed.value.host = host;
        refreshed.owned_host = host;
    }
    if (inspected.region) |region| {
        refreshed.value.region = region;
        refreshed.owned_region = region;
    }

    if (inspected.remote_state) |remote_state| {
        refreshed.value.remote_state = remote_state;
        refreshed.owned_remote_state = remote_state;
    } else {
        refreshed.value.remote_state = "unknown";
    }

    return refreshed;
}

fn resolveTrackedWorkspaceRecord(
    stderr: anytype,
    machine: model.MachineRecord,
    machine_name: []const u8,
    selector: []const u8,
) !model.WorkspaceRecord {
    return workspace.resolveTrackedSelector(machine, selector) catch |err| switch (err) {
        error.WorkspaceNotFound => {
            try std.fmt.format(
                stderr,
                "[error] machine '{s}' has no tracked workspace matching '{s}'\n" ++
                    "[hint] use the workspace label, local path, or remote path from `rove workspaces {s}`\n",
                .{ machine_name, selector, machine_name },
            );
            return error.HandledFailure;
        },
        error.AmbiguousWorkspaceSelector => {
            try std.fmt.format(
                stderr,
                "[error] workspace selector '{s}' is ambiguous for machine '{s}'\n" ++
                    "[hint] use the full local path or remote path to disambiguate\n",
                .{ selector, machine_name },
            );
            return error.HandledFailure;
        },
        else => return err,
    };
}

fn openWorkspaceSsh(
    allocator: std.mem.Allocator,
    stderr: anytype,
    machine: model.MachineRecord,
    machine_name: []const u8,
    selector: []const u8,
) !std.process.Child.Term {
    const tracked = try resolveTrackedWorkspaceRecord(stderr, machine, machine_name, selector);
    const resolved = try workspace.fromRecord(allocator, tracked);
    defer resolved.deinit(allocator);

    const planned = try tmux.planTrackedWorkspaceSession(allocator, resolved, tracked.tmux_session);
    defer planned.deinit(allocator);

    tmux.applyRemote(allocator, machine, planned) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to prepare tmux workspace '{s}' on machine '{s}': {s}\n",
            .{ selector, machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    const attach_command = try tmux.attachCommand(allocator, planned);
    defer allocator.free(attach_command);

    return ssh.openInteractiveCommand(allocator, machine, attach_command) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to start workspace ssh for machine '{s}': {s}\n",
            .{ machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };
}

fn performOffload(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    machine: *model.MachineRecord,
    machine_name: []const u8,
    resolved: workspace.ResolvedWorkspace,
    planned: tmux.PlannedRestore,
) !void {
    machine.status = .offloading;
    try state.upsertMachine(allocator, machine.*, null);

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
        machine,
        machine_name,
        resolved,
        .offloading,
        .offload_failed,
    );

    tmux.applyRemote(allocator, machine.*, planned.restore) catch |err| {
        machine.status = .offload_failed;
        try state.upsertMachine(allocator, machine.*, null);

        try std.fmt.format(
            stderr,
            "[error] tmux restore failed for machine '{s}': {s}\n",
            .{ machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    const tracked_workspaces = try workspace.mergeTracked(allocator, machine.*, workspace.buildRecord(resolved, planned.restore.session_name));
    defer tracked_workspaces.deinit(allocator);

    machine.workspace = tracked_workspaces.active;
    machine.workspaces = tracked_workspaces.records;
    machine.status = .ready;
    try state.upsertMachine(allocator, machine.*, null);

    if (ran_bootstrap_hook) {
        try stdout.writeAll("[info] ran repo-local bootstrap hook .rove/bootstrap.sh\n");
    }

    const attach_command = try tmux.attachCommand(allocator, planned.restore);
    defer allocator.free(attach_command);

    const term = ssh.openInteractiveCommand(allocator, machine.*, attach_command) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to attach remote tmux for machine '{s}': {s}\n",
            .{ machine_name, @errorName(err) },
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

test "parse workspaces target" {
    const command = try parse(&.{ "workspaces", "sam-east" });

    switch (command) {
        .workspaces => |name| try std.testing.expectEqualStrings("sam-east", name),
        else => return error.InvalidArguments,
    }
}

test "parse pull target" {
    const command = try parse(&.{ "pull", "sam-east" });

    switch (command) {
        .pull => |pull_command| {
            try std.testing.expectEqualStrings("sam-east", pull_command.machine_name);
            try std.testing.expect(!pull_command.preview);
            try std.testing.expect(!pull_command.force);
            try std.testing.expect(pull_command.workspace_selector == null);
        },
        else => return error.InvalidArguments,
    }
}

test "parse pull target with preview and force" {
    const command = try parse(&.{ "pull", "sam-east", "--workspace", "$HOME/work/repo", "--preview", "--force" });

    switch (command) {
        .pull => |pull_command| {
            try std.testing.expectEqualStrings("sam-east", pull_command.machine_name);
            try std.testing.expect(pull_command.preview);
            try std.testing.expect(pull_command.force);
            try std.testing.expectEqualStrings("$HOME/work/repo", pull_command.workspace_selector.?);
        },
        else => return error.InvalidArguments,
    }
}

test "parse ssh target with workspace selector" {
    const command = try parse(&.{ "ssh", "sam-east", "--workspace", "project" });

    switch (command) {
        .ssh => |ssh_command| {
            try std.testing.expectEqualStrings("sam-east", ssh_command.machine_name);
            try std.testing.expectEqualStrings("project", ssh_command.workspace_selector.?);
        },
        else => return error.InvalidArguments,
    }
}

test "parse offload target with workspace selector" {
    const command = try parse(&.{ "offload", "sam-east", "--workspace", "$HOME/work/project" });

    switch (command) {
        .offload => |offload_command| {
            try std.testing.expectEqualStrings("sam-east", offload_command.machine_name);
            try std.testing.expectEqualStrings("$HOME/work/project", offload_command.workspace_selector.?);
        },
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
