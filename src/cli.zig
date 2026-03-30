const std = @import("std");
const auth = @import("auth.zig");
const bootstrap = @import("bootstrap.zig");
const config = @import("config.zig");
const exec = @import("exec.zig");
const keys = @import("keys.zig");
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

pub const SyncCommand = struct {
    machine_name: []const u8,
    preview: bool = false,
    delete: bool = false,
};

pub const RefreshCommand = struct {
    machine_name: ?[]const u8 = null,
    prune_missing: bool = false,
};

pub const DoctorCommand = struct {
    machine_name: ?[]const u8 = null,
};

pub const AdoptCommand = struct {
    target: []const u8,
    machine_id: []const u8,
    name: ?[]const u8 = null,
};

pub const AuthCommand = struct {
    machine_name: []const u8,
    copy_gh: bool = false,
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
    refresh: RefreshCommand,
    doctor: DoctorCommand,
    adopt: AdoptCommand,
    auth: AuthCommand,
    run: RunCommand,
    sync: SyncCommand,
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
        .refresh => |refresh_command| try handleRefresh(allocator, stdout, stderr, refresh_command),
        .doctor => |doctor_command| try handleDoctor(allocator, stdout, stderr, doctor_command),
        .adopt => |adopt_command| try handleAdopt(allocator, stdout, stderr, adopt_command),
        .auth => |auth_command| try handleAuth(allocator, stdout, stderr, auth_command),
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

    if (std.mem.eql(u8, args[0], "refresh")) {
        return .{ .refresh = try parseRefreshCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "doctor")) {
        return .{ .doctor = try parseDoctorCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "adopt")) {
        return .{ .adopt = try parseAdoptCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "auth")) {
        return .{ .auth = try parseAuthCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "sync")) {
        return .{ .sync = try parseSyncCommand(args) };
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

fn parseRefreshCommand(args: []const []const u8) ParseError!RefreshCommand {
    var command = RefreshCommand{};

    var index: usize = 1;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--prune-missing")) {
            if (command.prune_missing) return error.InvalidArguments;
            command.prune_missing = true;
            index += 1;
            continue;
        }

        if (command.machine_name != null) return error.InvalidArguments;
        if (args[index].len == 0) return error.InvalidArguments;
        command.machine_name = args[index];
        index += 1;
    }

    return command;
}

fn parseDoctorCommand(args: []const []const u8) ParseError!DoctorCommand {
    if (args.len > 2) return error.InvalidArguments;

    return .{
        .machine_name = if (args.len == 2) args[1] else null,
    };
}

fn parseAdoptCommand(args: []const []const u8) ParseError!AdoptCommand {
    if (args.len < 3) return error.InvalidArguments;
    if (args[1].len == 0 or args[2].len == 0) return error.InvalidArguments;

    var command = AdoptCommand{
        .target = args[1],
        .machine_id = args[2],
    };

    var index: usize = 3;
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

fn parseAuthCommand(args: []const []const u8) ParseError!AuthCommand {
    if (args.len < 2) return error.InvalidArguments;
    if (args[1].len == 0) return error.InvalidArguments;

    var command = AuthCommand{
        .machine_name = args[1],
    };

    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--copy-gh")) {
            if (command.copy_gh) return error.InvalidArguments;
            command.copy_gh = true;
            index += 1;
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

fn parseSyncCommand(args: []const []const u8) ParseError!SyncCommand {
    if (args.len < 2) return error.InvalidArguments;
    if (args[1].len == 0) return error.InvalidArguments;

    var command = SyncCommand{
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

        if (std.mem.eql(u8, args[index], "--delete")) {
            if (command.delete) return error.InvalidArguments;
            command.delete = true;
            index += 1;
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
        \\  rove refresh [name] [--prune-missing]
        \\  rove doctor [name]
        \\  rove adopt <target> <machine-id> [--name <name>]
        \\  rove auth <name> [--copy-gh]
        \\  rove run <target> [--name <name>]
        \\  rove sync <name> [--preview] [--delete]
        \\  rove pull <name> [--workspace <selector>] [--preview] [--force]
        \\  rove workspaces <name>
        \\  rove offload <name> [--workspace <selector>]
        \\  rove status
        \\  rove ssh <name> [--workspace <selector>]
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
        \\  `refresh` updates local state from the provider for one machine or all machines
        \\  `refresh --prune-missing` removes tracked machines that no longer exist remotely
        \\  `doctor` checks local prerequisites, pinned images, auth material, and tracked machine health
        \\  `adopt` imports an existing provider machine into local state
        \\  `auth` installs Rove's SSH Git access material on the remote machine without relying on agent forwarding
        \\  `auth --copy-gh` also copies local GitHub CLI auth to the remote machine
        \\  `sync`, `pull`, `workspaces`, `offload`, `ssh`, and `down` address the tracked instance name
        \\  `sync --preview` shows rsync changes to the remote workspace without writing files
        \\  `sync --delete` removes remote files that no longer exist locally
        \\  `pull --workspace`, `ssh --workspace`, and `offload --workspace` accept `active`, an index from `workspaces`, a label, a local path, or a remote path
        \\  `pull --preview` shows rsync changes without writing local files
        \\  `pull` refuses to overwrite a dirty local git repo unless `--force` is set
        \\  `.roveignore` adds repo-local rsync exclusion rules for sync and offload
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

fn handleRefresh(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: RefreshCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    if (loaded_state.value.machines.len == 0) {
        try stdout.writeAll(
            "[info] no tracked machines\n" ++
                "[hint] use `rove run <target>` or `rove adopt <target> <machine-id>` first\n",
        );
        return;
    }

    try stdout.writeAll("NAME\tRESULT\tSTATUS\tREMOTE\tHOST\n");

    if (command.machine_name) |machine_name| {
        const machine = state.findMachine(&loaded_state.value, machine_name) orelse {
            try std.fmt.format(
                stderr,
                "[error] no tracked machine named '{s}'\n" ++
                    "[hint] use `rove status` to inspect tracked machines\n",
                .{machine_name},
            );
            return error.HandledFailure;
        };

        try refreshAndReportMachine(allocator, stdout, stderr, machine.*, command.prune_missing);
        return;
    }

    var had_failures = false;
    for (loaded_state.value.machines) |machine| {
        refreshAndReportMachine(allocator, stdout, stderr, machine, command.prune_missing) catch |err| switch (err) {
            error.HandledFailure => had_failures = true,
            else => return err,
        };
    }

    if (had_failures) {
        try stderr.writeAll("[warn] some tracked machines could not be refreshed cleanly\n");
    }
}

fn handleDoctor(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: DoctorCommand,
) !void {
    try stdout.writeAll("CHECK\tSTATUS\tDETAILS\n");

    var has_errors = false;

    doctorExecCheck(allocator, stdout, "flyctl", &.{ "flyctl", "version" }, "flyctl is available", &has_errors);
    doctorExecCheck(allocator, stdout, "fly auth", &.{ "flyctl", "auth", "whoami" }, "Fly auth is configured", &has_errors);

    var loaded_config = config.load(allocator, null) catch |err| switch (err) {
        error.FileNotFound => {
            has_errors = true;
            try printDoctorRow(stdout, "config", "error", "missing rove.json");
            return error.HandledFailure;
        },
        else => return err,
    };
    defer loaded_config.deinit();

    try printDoctorRow(stdout, "config", "ok", "loaded rove.json");
    for (loaded_config.value.targets) |target| {
        const detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{
            target.name,
            if (isPinnedImageRef(target.image)) "pinned image ref" else "unpinned image ref",
        });
        defer allocator.free(detail);

        try printDoctorRow(
            stdout,
            "image",
            if (isPinnedImageRef(target.image)) "ok" else "warn",
            detail,
        );
    }

    const managed_key = keys.ensureManagedKeyPair(allocator) catch |err| {
        has_errors = true;
        try printDoctorRow(stdout, "machine ssh key", "error", @errorName(err));
        return error.HandledFailure;
    };
    defer managed_key.deinit(allocator);
    try printDoctorRow(stdout, "machine ssh key", "ok", "managed machine SSH key is present");

    const git_auth_key = keys.ensureGitAuthKeyPair(allocator) catch |err| {
        has_errors = true;
        try printDoctorRow(stdout, "git auth key", "error", @errorName(err));
        return error.HandledFailure;
    };
    defer git_auth_key.deinit(allocator);
    try printDoctorRow(stdout, "git auth key", "ok", "dedicated Git auth SSH key is present");

    const local_gh_auth = try auth.localGhAuthAvailable(allocator);
    try printDoctorRow(
        stdout,
        "gh auth",
        "ok",
        if (local_gh_auth)
            "local GitHub CLI auth is available for optional `rove auth <name> --copy-gh`"
        else
            "local gh auth not found; remote gh auth sync is disabled unless explicitly requested",
    );

    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    if (loaded_state.value.machines.len == 0) {
        try printDoctorRow(stdout, "tracked machines", "ok", "no tracked machines");
    } else if (command.machine_name) |machine_name| {
        const machine = state.findMachine(&loaded_state.value, machine_name) orelse {
            has_errors = true;
            try printDoctorRow(stdout, "tracked machine", "error", "requested machine is not tracked");
            return error.HandledFailure;
        };
        try doctorTrackedMachine(allocator, stdout, machine.*, &has_errors);
    } else {
        for (loaded_state.value.machines) |machine| {
            try doctorTrackedMachine(allocator, stdout, machine, &has_errors);
        }
    }

    if (has_errors) {
        try stderr.writeAll("[warn] doctor found one or more errors\n");
        return error.HandledFailure;
    }
}

fn handleAuth(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: AuthCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine = state.findMachine(&loaded_state.value, command.machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run or adopt a machine before syncing auth\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    };

    const result = auth.syncGitHubAccess(allocator, machine.*, .{
        .copy_gh_auth = command.copy_gh,
    }) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to sync remote auth for machine '{s}': {s}\n",
            .{ command.machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };
    defer result.deinit(allocator);

    try std.fmt.format(
        stdout,
        "[info] installed Git auth material on machine '{s}'\n" ++
            "[info] local private repos over SSH will use ~/.ssh/rove_git_ed25519 on the remote box\n",
        .{command.machine_name},
    );

    if (command.copy_gh and result.gh_config_synced) {
        try stdout.writeAll("[info] synced local gh auth config to the remote machine\n");
    } else if (command.copy_gh) {
        try stdout.writeAll("[warn] local gh auth config was not found; only SSH Git auth was installed\n");
    } else {
        try stdout.writeAll("[info] skipped local gh auth sync; pass `--copy-gh` to copy GitHub CLI auth intentionally\n");
    }

    if (result.git_identity_synced) {
        try stdout.writeAll("[info] synced local global git identity to the remote machine\n");
    }

    try std.fmt.format(
        stdout,
        "[hint] add this public key to GitHub once if private SSH remotes fail:\n{s}\n",
        .{result.public_key},
    );
}

fn handleAdopt(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: AdoptCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    var loaded_config = config.load(allocator, null) catch |err| switch (err) {
        error.FileNotFound => {
            try std.fmt.format(
                stderr,
                "[error] missing config file '{s}'\n" ++
                    "[hint] create it before adopting a target\n",
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

    if (state.findMachineById(&loaded_state.value, command.machine_id)) |existing| {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' is already tracked as '{s}'\n" ++
                "[hint] use `rove refresh {s}` or `rove status` to inspect it\n",
            .{ command.machine_id, existing.name, existing.name },
        );
        return error.HandledFailure;
    }

    const inspected = try provider.inspect(allocator, target.provider, .{
        .app = target.app,
        .machine_id = command.machine_id,
    });
    defer inspected.deinit(allocator);

    if (!inspected.exists) {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' was not found in app '{s}'\n",
            .{ command.machine_id, target.app },
        );
        return error.HandledFailure;
    }

    const adopted_name = command.name orelse inspected.machine_name orelse command.machine_id;
    if (!isValidInstanceName(adopted_name)) {
        try std.fmt.format(
            stderr,
            "[error] invalid adopted instance name '{s}'\n" ++
                "[hint] pass `--name` with letters, digits, '-', '_' or '.' only\n",
            .{adopted_name},
        );
        return error.HandledFailure;
    }

    if (state.findMachine(&loaded_state.value, adopted_name) != null) {
        try std.fmt.format(
            stderr,
            "[error] instance '{s}' already exists in local state\n" ++
                "[hint] choose a different `--name` or remove the existing entry first\n",
            .{adopted_name},
        );
        return error.HandledFailure;
    }

    const fallback_host = try std.fmt.allocPrint(allocator, "{s}.fly.dev", .{target.app});
    defer allocator.free(fallback_host);

    const machine = model.MachineRecord{
        .name = adopted_name,
        .target_name = target.name,
        .provider = target.provider,
        .id = command.machine_id,
        .machine_name = inspected.machine_name,
        .app = target.app,
        .host = inspected.host orelse fallback_host,
        .region = inspected.region,
        .remote_state = inspected.remote_state,
        .ssh_user = target.ssh_user,
        .status = lifecycleFromRemoteState(inspected.remote_state, .provisioned),
    };

    try state.upsertMachine(allocator, machine, null);

    try std.fmt.format(
        stdout,
        "[info] adopted machine '{s}' as instance '{s}'\n" ++
            "[info] target: {s}\n" ++
            "[info] provider: {s}\n" ++
            "[info] app: {s}\n" ++
            "[info] host: {s}\n" ++
            "[info] remote_state: {s}\n",
        .{
            command.machine_id,
            adopted_name,
            target.name,
            model.providerName(target.provider),
            target.app,
            machine.host,
            machine.remote_state orelse "unknown",
        },
    );
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

    const term = term: {
        if (command.workspace_selector) |selector| {
            break :term try openWorkspaceSsh(allocator, stderr, machine.*, command.machine_name, selector);
        }

        if (workspace.activeTracked(machine.*)) |tracked| {
            break :term openTrackedWorkspaceSsh(
                allocator,
                stderr,
                machine.*,
                command.machine_name,
                tracked,
                workspace.recordName(tracked),
            ) catch |err| switch (err) {
                error.HandledFailure => {
                    try std.fmt.format(
                        stderr,
                        "[warn] failed to attach the active workspace for '{s}'; falling back to a raw shell\n",
                        .{command.machine_name},
                    );
                    break :term try openRawSsh(allocator, stderr, machine.*, command.machine_name);
                },
                else => return err,
            };
        }

        break :term try openRawSsh(allocator, stderr, machine.*, command.machine_name);
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
    try stdout.writeAll("INDEX\tACTIVE\tNAME\tLOCAL\tREMOTE\tTMUX\n");

    if (machine.workspaces.len > 0) {
        for (machine.workspaces, 0..) |tracked, index| {
            try printWorkspaceRow(stdout, index + 1, tracked, active);
        }
    } else if (machine.workspace) |tracked| {
        try printWorkspaceRow(stdout, 1, tracked, active);
    }

    try std.fmt.format(
        stdout,
        "[hint] use `--workspace active`, `--workspace <index>`, a label, a local path, or a remote path with `rove pull {s}`, `rove ssh {s}`, or `rove offload {s}`\n",
        .{ machine_name, machine_name, machine_name },
    );
}

fn printWorkspaceRow(
    stdout: anytype,
    index: usize,
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
        "{d}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
        .{
            index,
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
    command: SyncCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine_ptr = state.findMachine(&loaded_state.value, command.machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so there is a machine to sync into\n",
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
    const resolved = try workspace.discover(allocator, machine);
    defer resolved.deinit(allocator);

    if (command.preview) {
        var preview = sync.previewSyncWorkspace(allocator, machine, resolved, .{
            .delete = command.delete,
        }) catch |err| {
            try std.fmt.format(
                stderr,
                "[error] workspace sync preview failed for machine '{s}': {s}\n",
                .{ command.machine_name, @errorName(err) },
            );
            return error.HandledFailure;
        };
        defer preview.deinit(allocator);

        try std.fmt.format(
            stdout,
            "[info] previewing sync from '{s}' to {s}\n",
            .{ resolved.local_root, resolved.remote_root },
        );
        if (command.delete) {
            try stdout.writeAll("[info] preview includes remote deletions because --delete was set\n");
        }

        if (preview.hasChanges()) {
            try stdout.writeAll(preview.changes);
        } else {
            try stdout.writeAll("[info] no local changes detected\n");
        }
        return;
    }

    try std.fmt.format(
        stdout,
        "[info] syncing workspace '{s}' to {s}\n",
        .{ resolved.local_root, resolved.remote_root },
    );
    if (command.delete) {
        try stdout.writeAll("[info] deleting remote files missing from the local workspace because --delete was set\n");
    }

    const ran_bootstrap_hook = try syncResolvedWorkspace(
        allocator,
        stderr,
        &machine,
        command.machine_name,
        resolved,
        .syncing,
        .sync_failed,
        .{
            .delete = command.delete,
        },
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
        .{command.machine_name},
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
                    "[hint] use `active`, an index, a label, a local path, or a remote path from `rove workspaces {s}`\n",
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
    missing: bool = false,
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
        refreshed.value.status = lifecycleFromRemoteState(refreshed.value.remote_state, refreshed.value.status);
        refreshed.missing = true;
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
    refreshed.value.status = lifecycleFromRemoteState(refreshed.value.remote_state, refreshed.value.status);

    return refreshed;
}

fn refreshAndReportMachine(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    machine: model.MachineRecord,
    prune_missing: bool,
) !void {
    var refreshed = refreshMachineFromProvider(allocator, machine) catch |err| {
        try std.fmt.format(
            stderr,
            "[warn] failed to refresh machine '{s}': {s}\n",
            .{ machine.name, @errorName(err) },
        );
        return error.HandledFailure;
    };
    defer refreshed.deinit(allocator);

    if (prune_missing and refreshed.missing) {
        _ = try state.removeMachine(allocator, machine.name, null);
        try std.fmt.format(
            stdout,
            "{s}\tpruned\t{s}\tmissing\t-\n",
            .{ machine.name, model.statusName(refreshed.value.status) },
        );
        return;
    }

    try state.upsertMachine(allocator, refreshed.value, null);

    try std.fmt.format(
        stdout,
        "{s}\t{s}\t{s}\t{s}\t{s}\n",
        .{
            machine.name,
            if (refreshed.missing) "missing" else "updated",
            model.statusName(refreshed.value.status),
            refreshed.value.remote_state orelse "-",
            refreshed.value.host,
        },
    );
}

fn doctorTrackedMachine(
    allocator: std.mem.Allocator,
    stdout: anytype,
    machine: model.MachineRecord,
    has_errors: *bool,
) !void {
    var refreshed = refreshMachineFromProvider(allocator, machine) catch |err| {
        has_errors.* = true;
        const detail = try std.fmt.allocPrint(allocator, "{s}: refresh failed: {s}", .{ machine.name, @errorName(err) });
        defer allocator.free(detail);
        try printDoctorRow(stdout, "machine", "error", detail);
        return;
    };
    defer refreshed.deinit(allocator);

    try state.upsertMachine(allocator, refreshed.value, null);

    const remote_detail = try std.fmt.allocPrint(allocator, "{s}: remote state {s}", .{
        machine.name,
        refreshed.value.remote_state orelse "unknown",
    });
    defer allocator.free(remote_detail);

    if (refreshed.missing) {
        has_errors.* = true;
        try printDoctorRow(stdout, "machine", "warn", remote_detail);
        return;
    }

    try printDoctorRow(stdout, "machine", "ok", remote_detail);

    ssh.preflight(allocator, refreshed.value) catch |err| {
        has_errors.* = true;
        const detail = try std.fmt.allocPrint(allocator, "{s}: ssh preflight failed: {s}", .{ machine.name, @errorName(err) });
        defer allocator.free(detail);
        try printDoctorRow(stdout, "ssh", "error", detail);
        return;
    };

    const ssh_detail = try std.fmt.allocPrint(allocator, "{s}: SSH is reachable", .{machine.name});
    defer allocator.free(ssh_detail);
    try printDoctorRow(stdout, "ssh", "ok", ssh_detail);
}

fn doctorExecCheck(
    allocator: std.mem.Allocator,
    stdout: anytype,
    check_name: []const u8,
    argv: []const []const u8,
    ok_detail: []const u8,
    has_errors: *bool,
) void {
    const result = exec.run(allocator, argv) catch |err| {
        has_errors.* = true;
        const detail = std.fmt.allocPrint(allocator, "{s}: {s}", .{ check_name, @errorName(err) }) catch return;
        defer allocator.free(detail);
        printDoctorRow(stdout, check_name, "error", detail) catch {};
        return;
    };
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        has_errors.* = true;
        const stderr = std.mem.trim(u8, result.stderr, "\r\n\t ");
        const detail = if (stderr.len > 0)
            std.fmt.allocPrint(allocator, "{s}: {s}", .{ check_name, stderr }) catch return
        else
            std.fmt.allocPrint(allocator, "{s}: command failed", .{check_name}) catch return;
        defer allocator.free(detail);
        printDoctorRow(stdout, check_name, "error", detail) catch {};
        return;
    }

    printDoctorRow(stdout, check_name, "ok", ok_detail) catch {};
}

fn printDoctorRow(
    stdout: anytype,
    check_name: []const u8,
    status: []const u8,
    detail: []const u8,
) !void {
    try std.fmt.format(stdout, "{s}\t{s}\t{s}\n", .{ check_name, status, detail });
}

fn isPinnedImageRef(image: []const u8) bool {
    return std.mem.indexOf(u8, image, "@sha256:") != null;
}

fn lifecycleFromRemoteState(
    remote_state: ?[]const u8,
    fallback: model.LifecycleStatus,
) model.LifecycleStatus {
    const value = remote_state orelse return fallback;

    if (std.ascii.eqlIgnoreCase(value, "started") or std.ascii.eqlIgnoreCase(value, "running")) {
        return .ready;
    }

    if (std.ascii.eqlIgnoreCase(value, "created") or
        std.ascii.eqlIgnoreCase(value, "starting") or
        std.ascii.eqlIgnoreCase(value, "pending"))
    {
        return .provisioned;
    }

    if (std.ascii.eqlIgnoreCase(value, "stopped") or
        std.ascii.eqlIgnoreCase(value, "suspended") or
        std.ascii.eqlIgnoreCase(value, "failed") or
        std.ascii.eqlIgnoreCase(value, "destroyed") or
        std.ascii.eqlIgnoreCase(value, "missing"))
    {
        return .provisioned_unreachable;
    }

    return fallback;
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
                    "[hint] use `active`, an index, a label, a local path, or a remote path from `rove workspaces {s}`\n",
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
    return openTrackedWorkspaceSsh(allocator, stderr, machine, machine_name, tracked, selector);
}

fn openTrackedWorkspaceSsh(
    allocator: std.mem.Allocator,
    stderr: anytype,
    machine: model.MachineRecord,
    machine_name: []const u8,
    tracked: model.WorkspaceRecord,
    selector_label: []const u8,
) !std.process.Child.Term {
    const resolved = try workspace.fromRecord(allocator, tracked);
    defer resolved.deinit(allocator);

    const planned = try tmux.planTrackedWorkspaceSession(allocator, resolved, tracked.tmux_session);
    defer planned.deinit(allocator);

    tmux.applyRemote(allocator, machine, planned) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to prepare tmux workspace '{s}' on machine '{s}': {s}\n",
            .{ selector_label, machine_name, @errorName(err) },
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

fn openRawSsh(
    allocator: std.mem.Allocator,
    stderr: anytype,
    machine: model.MachineRecord,
    machine_name: []const u8,
) !std.process.Child.Term {
    return ssh.openInteractive(allocator, machine) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to start ssh for machine '{s}': {s}\n",
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
        .{},
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
    sync_options: sync.SyncOptions,
) !bool {
    machine.status = active_status;
    try state.upsertMachine(allocator, machine.*, null);

    const result = sync.syncWorkspace(allocator, machine.*, resolved, sync_options) catch |err| {
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

test "parse refresh all with prune" {
    const command = try parse(&.{ "refresh", "--prune-missing" });

    switch (command) {
        .refresh => |refresh_command| {
            try std.testing.expect(refresh_command.machine_name == null);
            try std.testing.expect(refresh_command.prune_missing);
        },
        else => return error.InvalidArguments,
    }
}

test "parse refresh target" {
    const command = try parse(&.{ "refresh", "sam-east" });

    switch (command) {
        .refresh => |refresh_command| {
            try std.testing.expectEqualStrings("sam-east", refresh_command.machine_name.?);
            try std.testing.expect(!refresh_command.prune_missing);
        },
        else => return error.InvalidArguments,
    }
}

test "parse doctor target" {
    const command = try parse(&.{ "doctor", "sam-east" });

    switch (command) {
        .doctor => |doctor_command| try std.testing.expectEqualStrings("sam-east", doctor_command.machine_name.?),
        else => return error.InvalidArguments,
    }
}

test "parse adopt target" {
    const command = try parse(&.{ "adopt", "devbox", "machine-123", "--name", "sam-east" });

    switch (command) {
        .adopt => |adopt_command| {
            try std.testing.expectEqualStrings("devbox", adopt_command.target);
            try std.testing.expectEqualStrings("machine-123", adopt_command.machine_id);
            try std.testing.expectEqualStrings("sam-east", adopt_command.name.?);
        },
        else => return error.InvalidArguments,
    }
}

test "parse auth target" {
    const command = try parse(&.{ "auth", "sam-east" });

    switch (command) {
        .auth => |auth_command| {
            try std.testing.expectEqualStrings("sam-east", auth_command.machine_name);
            try std.testing.expect(!auth_command.copy_gh);
        },
        else => return error.InvalidArguments,
    }
}

test "parse auth target with copy gh" {
    const command = try parse(&.{ "auth", "sam-east", "--copy-gh" });

    switch (command) {
        .auth => |auth_command| {
            try std.testing.expectEqualStrings("sam-east", auth_command.machine_name);
            try std.testing.expect(auth_command.copy_gh);
        },
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
        .sync => |sync_command| {
            try std.testing.expectEqualStrings("sam-east", sync_command.machine_name);
            try std.testing.expect(!sync_command.preview);
            try std.testing.expect(!sync_command.delete);
        },
        else => return error.InvalidArguments,
    }
}

test "parse sync target with preview and delete" {
    const command = try parse(&.{ "sync", "sam-east", "--preview", "--delete" });

    switch (command) {
        .sync => |sync_command| {
            try std.testing.expectEqualStrings("sam-east", sync_command.machine_name);
            try std.testing.expect(sync_command.preview);
            try std.testing.expect(sync_command.delete);
        },
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
