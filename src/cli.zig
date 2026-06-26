const std = @import("std");
const bootstrap = @import("bootstrap.zig");
const config = @import("config.zig");
const exec = @import("exec.zig");
const keys = @import("keys.zig");
const model = @import("model.zig");
const paths = @import("paths.zig");
const provider = @import("provider/mod.zig");
const shell = @import("shell.zig");
const ssh = @import("ssh.zig");
const state = @import("state.zig");

pub const ParseError = error{
    InvalidArguments,
};

pub const HandledFailure = error{
    HandledFailure,
};

const OutputFormat = enum {
    human,
    json,
};

pub const ListCommand = struct {
    format: OutputFormat = .human,
};

pub const RunCommand = struct {
    target: []const u8,
    name: ?[]const u8 = null,
    format: OutputFormat = .human,
    progress_jsonl: bool = false,
};

pub const StatusCommand = struct {
    machine_name: ?[]const u8 = null,
    format: OutputFormat = .human,
};

pub const RefreshCommand = struct {
    machine_name: ?[]const u8 = null,
    prune_missing: bool = false,
    format: OutputFormat = .human,
};

pub const DoctorCommand = struct {
    machine_name: ?[]const u8 = null,
};

pub const AdoptCommand = struct {
    target: []const u8,
    machine_id: []const u8,
    name: ?[]const u8 = null,
    format: OutputFormat = .human,
};

pub const ExecCommand = struct {
    machine_name: []const u8,
    argv: []const []const u8,
};

pub const MachineCommand = struct {
    machine_name: []const u8,
    format: OutputFormat = .human,
};

pub const Command = union(enum) {
    help,
    list: ListCommand,
    status: StatusCommand,
    inspect: MachineCommand,
    refresh: RefreshCommand,
    doctor: DoctorCommand,
    adopt: AdoptCommand,
    up: RunCommand,
    run: RunCommand,
    ssh: []const u8,
    exec: ExecCommand,
    down: MachineCommand,
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
        .list => |list_command| try handleList(allocator, stdout, stderr, list_command),
        .status => |status_command| try handleStatus(allocator, stdout, stderr, status_command),
        .inspect => |machine_command| try handleInspect(allocator, stdout, stderr, machine_command),
        .refresh => |refresh_command| try handleRefresh(allocator, stdout, stderr, refresh_command),
        .doctor => |doctor_command| try handleDoctor(allocator, stdout, stderr, doctor_command),
        .adopt => |adopt_command| try handleAdopt(allocator, stdout, stderr, adopt_command),
        .up => |run_command| try handleRun(allocator, stdout, stderr, run_command),
        .run => |run_command| try handleRun(allocator, stdout, stderr, run_command),
        .ssh => |machine_name| try handleSsh(allocator, stdout, stderr, machine_name),
        .exec => |exec_command| try handleExec(allocator, stdout, stderr, exec_command),
        .down => |machine_command| try handleDown(allocator, stdout, stderr, machine_command),
    }
}

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .help;

    if (std.mem.eql(u8, args[0], "help") or
        std.mem.eql(u8, args[0], "--help") or
        std.mem.eql(u8, args[0], "-h"))
    {
        if (args.len != 1) return error.InvalidArguments;
        return .help;
    }

    if (std.mem.eql(u8, args[0], "list") or std.mem.eql(u8, args[0], "ls")) {
        return .{ .list = try parseListCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "status")) {
        return .{ .status = try parseStatusCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "inspect")) {
        return .{ .inspect = try parseMachineCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "refresh")) {
        return .{ .refresh = try parseRefreshCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "doctor")) {
        if (args.len > 2) return error.InvalidArguments;
        return .{ .doctor = .{ .machine_name = if (args.len == 2) try nonEmpty(args[1]) else null } };
    }

    if (std.mem.eql(u8, args[0], "adopt")) {
        return .{ .adopt = try parseAdoptCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "up")) {
        return .{ .up = try parseRunCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "run")) {
        return .{ .run = try parseRunCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "ssh")) {
        return .{ .ssh = try expectSingleTarget(args) };
    }

    if (std.mem.eql(u8, args[0], "exec")) {
        return .{ .exec = try parseExecCommand(args) };
    }

    if (std.mem.eql(u8, args[0], "down")) {
        return .{ .down = try parseMachineCommand(args) };
    }

    return error.InvalidArguments;
}

fn nonEmpty(value: []const u8) ParseError![]const u8 {
    if (value.len == 0) return error.InvalidArguments;
    return value;
}

fn expectSingleTarget(args: []const []const u8) ParseError![]const u8 {
    if (args.len != 2) return error.InvalidArguments;
    return nonEmpty(args[1]);
}

fn parseListCommand(args: []const []const u8) ParseError!ListCommand {
    var command = ListCommand{};

    var index: usize = 1;
    while (index < args.len) {
        if (try parseOutputFormatFlag(args[index], &command.format)) {
            index += 1;
            continue;
        }

        return error.InvalidArguments;
    }

    return command;
}

fn parseStatusCommand(args: []const []const u8) ParseError!StatusCommand {
    var command = StatusCommand{};

    var index: usize = 1;
    while (index < args.len) {
        if (try parseOutputFormatFlag(args[index], &command.format)) {
            index += 1;
            continue;
        }

        if (command.machine_name != null) return error.InvalidArguments;
        command.machine_name = try nonEmpty(args[index]);
        index += 1;
    }

    return command;
}

fn parseRunCommand(args: []const []const u8) ParseError!RunCommand {
    if (args.len < 2) return error.InvalidArguments;

    var command = RunCommand{
        .target = try nonEmpty(args[1]),
    };

    var index: usize = 2;
    while (index < args.len) {
        if (try parseOutputFormatFlag(args[index], &command.format)) {
            index += 1;
            continue;
        }

        if (std.mem.eql(u8, args[index], "--name")) {
            if (command.name != null) return error.InvalidArguments;
            if (index + 1 >= args.len) return error.InvalidArguments;
            command.name = try nonEmpty(args[index + 1]);
            index += 2;
            continue;
        }

        if (std.mem.eql(u8, args[index], "--progress-jsonl")) {
            if (command.progress_jsonl) return error.InvalidArguments;
            command.progress_jsonl = true;
            index += 1;
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
        if (try parseOutputFormatFlag(args[index], &command.format)) {
            index += 1;
            continue;
        }

        if (std.mem.eql(u8, args[index], "--prune-missing")) {
            if (command.prune_missing) return error.InvalidArguments;
            command.prune_missing = true;
            index += 1;
            continue;
        }

        if (command.machine_name != null) return error.InvalidArguments;
        command.machine_name = try nonEmpty(args[index]);
        index += 1;
    }

    return command;
}

fn parseAdoptCommand(args: []const []const u8) ParseError!AdoptCommand {
    if (args.len < 3) return error.InvalidArguments;

    var command = AdoptCommand{
        .target = try nonEmpty(args[1]),
        .machine_id = try nonEmpty(args[2]),
    };

    var index: usize = 3;
    while (index < args.len) {
        if (try parseOutputFormatFlag(args[index], &command.format)) {
            index += 1;
            continue;
        }

        if (std.mem.eql(u8, args[index], "--name")) {
            if (command.name != null) return error.InvalidArguments;
            if (index + 1 >= args.len) return error.InvalidArguments;
            command.name = try nonEmpty(args[index + 1]);
            index += 2;
            continue;
        }

        return error.InvalidArguments;
    }

    return command;
}

fn parseMachineCommand(args: []const []const u8) ParseError!MachineCommand {
    if (args.len < 2) return error.InvalidArguments;

    var command = MachineCommand{
        .machine_name = try nonEmpty(args[1]),
    };

    var index: usize = 2;
    while (index < args.len) {
        if (try parseOutputFormatFlag(args[index], &command.format)) {
            index += 1;
            continue;
        }

        return error.InvalidArguments;
    }

    return command;
}

fn parseExecCommand(args: []const []const u8) ParseError!ExecCommand {
    if (args.len < 4) return error.InvalidArguments;
    if (!std.mem.eql(u8, args[2], "--")) return error.InvalidArguments;

    return .{
        .machine_name = try nonEmpty(args[1]),
        .argv = args[3..],
    };
}

fn parseOutputFormatFlag(
    arg: []const u8,
    format: *OutputFormat,
) ParseError!bool {
    if (!std.mem.eql(u8, arg, "--json")) return false;
    if (format.* == .json) return error.InvalidArguments;
    format.* = .json;
    return true;
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\rove
        \\
        \\Usage:
        \\  rove up <target> [--name <name>] [--json] [--progress-jsonl]
        \\  rove run <target> [--name <name>] [--json] [--progress-jsonl]
        \\  rove list [--json]
        \\  rove status [name] [--json]
        \\  rove inspect <name> [--json]
        \\  rove refresh [name] [--prune-missing] [--json]
        \\  rove doctor [name]
        \\  rove adopt <target> <machine-id> [--name <name>] [--json]
        \\  rove ssh <name>
        \\  rove exec <name> -- <command> [args...]
        \\  rove down <name> [--json]
        \\
        \\Rove provisions and tracks disposable machines. Workspace sync,
        \\terminal session state, and distributed control belong above this layer.
        \\
        \\Defaults:
        \\  config: ROVE_CONFIG, ./rove.json, ~/.config/rove/rove.json
        \\  state: ~/.rove/state.json
        \\
    );
}

fn appendJsonString(
    out: *std.Io.Writer.Allocating,
    value: []const u8,
) !void {
    try std.json.Stringify.value(value, .{}, &out.writer);
}

fn appendJsonNullableString(
    out: *std.Io.Writer.Allocating,
    value: ?[]const u8,
) !void {
    if (value) |unwrapped| {
        try appendJsonString(out, unwrapped);
    } else {
        try out.writer.writeAll("null");
    }
}

fn appendMachineJson(
    out: *std.Io.Writer.Allocating,
    machine: model.MachineRecord,
) !void {
    try out.writer.writeAll("{\"name\":");
    try appendJsonString(out, machine.name);
    try out.writer.writeAll(",\"target_name\":");
    try appendJsonNullableString(out, machine.target_name);
    try out.writer.writeAll(",\"provider\":");
    try appendJsonString(out, model.providerName(machine.provider));
    try out.writer.writeAll(",\"id\":");
    try appendJsonString(out, machine.id);
    try out.writer.writeAll(",\"machine_name\":");
    try appendJsonNullableString(out, machine.machine_name);
    try out.writer.writeAll(",\"provider_scope\":");
    try appendJsonNullableString(out, machine.provider_scope);
    try out.writer.writeAll(",\"app\":");
    try appendJsonNullableString(out, machine.app);
    try out.writer.writeAll(",\"host\":");
    try appendJsonString(out, machine.host);
    try out.writer.writeAll(",\"ssh_configured_host\":");
    try appendJsonString(out, model.configuredSshHost(machine));
    try out.writer.writeAll(",\"ssh_resolved_host\":");
    try appendJsonNullableString(out, machine.ssh_resolved_host);
    try out.writer.writeAll(",\"ssh_endpoint_host\":");
    try appendJsonString(out, model.endpointSshHost(machine));
    try out.writer.writeAll(",\"ssh_port\":");
    try std.json.Stringify.value(machine.ssh_port, .{}, &out.writer);
    try out.writer.writeAll(",\"ssh_resolver\":");
    try appendJsonString(out, model.sshResolverName(machine.ssh_resolver));
    try out.writer.writeAll(",\"require_private_ssh\":");
    try out.writer.writeAll(if (machine.require_private_ssh) "true" else "false");
    try out.writer.writeAll(",\"ssh_identity_file\":");
    try appendJsonNullableString(out, machine.ssh_identity_file);
    try out.writer.writeAll(",\"region\":");
    try appendJsonNullableString(out, machine.region);
    try out.writer.writeAll(",\"remote_state\":");
    try appendJsonNullableString(out, machine.remote_state);
    try out.writer.writeAll(",\"ssh_user\":");
    try appendJsonString(out, machine.ssh_user);
    try out.writer.writeAll(",\"status\":");
    try appendJsonString(out, model.statusName(machine.status));
    try out.writer.writeAll(",\"provider_metadata\":");
    if (machine.provider_metadata) |metadata| {
        try std.json.Stringify.value(metadata, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeByte('}');
}

fn writeMachineJsonDocument(
    allocator: std.mem.Allocator,
    stdout: anytype,
    machine: model.MachineRecord,
) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll("{\"machine\":");
    try appendMachineJson(&out, machine);
    try out.writer.writeAll("}\n");
    try stdout.writeAll(out.written());
}

const LaunchProgressContext = struct {
    enabled: bool,
    started_ms: i64,
    instance_name: []const u8,
    target_name: []const u8,
    provider: model.ProviderKind,
};

fn renderLaunchProgressEvent(
    allocator: std.mem.Allocator,
    progress: LaunchProgressContext,
    phase: []const u8,
    status_name: []const u8,
    machine: ?model.MachineRecord,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const now_ms = std.time.milliTimestamp();
    const elapsed_ms: u64 = if (now_ms <= progress.started_ms)
        0
    else
        @intCast(now_ms - progress.started_ms);

    try out.writer.writeAll("{\"type\":\"launch_progress\",\"phase\":");
    try appendJsonString(&out, phase);
    try out.writer.writeAll(",\"status\":");
    try appendJsonString(&out, status_name);
    try out.writer.writeAll(",\"elapsed_ms\":");
    try std.json.Stringify.value(elapsed_ms, .{}, &out.writer);
    try out.writer.writeAll(",\"instance_name\":");
    try appendJsonString(&out, progress.instance_name);
    try out.writer.writeAll(",\"target_name\":");
    try appendJsonString(&out, progress.target_name);
    try out.writer.writeAll(",\"provider\":");
    try appendJsonString(&out, model.providerName(progress.provider));
    try out.writer.writeAll(",\"machine_id\":");
    if (machine) |value| {
        try appendJsonString(&out, value.id);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"machine_name\":");
    if (machine) |value| {
        try appendJsonNullableString(&out, value.machine_name);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"ssh_configured_host\":");
    if (machine) |value| {
        try appendJsonString(&out, model.configuredSshHost(value));
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"ssh_resolved_host\":");
    if (machine) |value| {
        try appendJsonNullableString(&out, value.ssh_resolved_host);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"ssh_endpoint_host\":");
    if (machine) |value| {
        try appendJsonString(&out, model.endpointSshHost(value));
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"ssh_port\":");
    if (machine) |value| {
        try std.json.Stringify.value(value.ssh_port, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll("}\n");

    return allocator.dupe(u8, out.written());
}

fn emitLaunchProgress(
    allocator: std.mem.Allocator,
    writer: anytype,
    progress: LaunchProgressContext,
    phase: []const u8,
    status_name: []const u8,
    machine: ?model.MachineRecord,
) !void {
    if (!progress.enabled) return;

    const line = try renderLaunchProgressEvent(allocator, progress, phase, status_name, machine);
    defer allocator.free(line);
    try writer.writeAll(line);
}

fn appendRefreshResultJson(
    out: *std.Io.Writer.Allocating,
    result: RefreshReport,
) !void {
    try out.writer.writeAll("{\"name\":");
    try appendJsonString(out, result.refreshed.value.name);
    try out.writer.writeAll(",\"result\":");
    try appendJsonString(out, result.result);
    try out.writer.writeAll(",\"pruned\":");
    try out.writer.writeAll(if (result.pruned) "true" else "false");
    try out.writer.writeAll(",\"machine\":");
    try appendMachineJson(out, result.refreshed.value);
    try out.writer.writeByte('}');
}

fn handleList(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: ListCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    if (loaded_state.value.machines.len == 0) {
        if (command.format == .json) {
            try stdout.writeAll("{\"machines\":[]}\n");
            return;
        }

        try stdout.writeAll(
            "[info] no tracked machines\n" ++
                "[hint] new machines will be recorded in ~/.rove/state.json after `rove up <target>` succeeds\n",
        );
        return;
    }

    if (command.format == .json) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        try out.writer.writeAll("{\"machines\":[");
        for (loaded_state.value.machines, 0..) |machine, index| {
            var refreshed = refreshMachineFromProvider(allocator, machine) catch |err| fallback: {
                try std.fmt.format(
                    stderr,
                    "[warn] failed to refresh machine '{s}': {s}\n",
                    .{ machine.name, @errorName(err) },
                );

                var fallback = RefreshedMachine{ .value = machine };
                fallback.value.remote_state = "refresh_failed";
                break :fallback fallback;
            };
            defer refreshed.deinit(allocator);

            try state.upsertMachine(allocator, refreshed.value, null);
            if (index > 0) try out.writer.writeByte(',');
            try appendMachineJson(&out, refreshed.value);
        }
        try out.writer.writeAll("]}\n");
        try stdout.writeAll(out.written());
        return;
    }

    try stdout.writeAll("NAME\tTARGET\tPROVIDER\tSTATUS\tREMOTE\tSSH\tREGION\n");
    for (loaded_state.value.machines) |machine| {
        var refreshed = refreshMachineFromProvider(allocator, machine) catch |err| fallback: {
            try std.fmt.format(
                stderr,
                "[warn] failed to refresh machine '{s}': {s}\n",
                .{ machine.name, @errorName(err) },
            );

            var fallback = RefreshedMachine{ .value = machine };
            fallback.value.remote_state = "refresh_failed";
            break :fallback fallback;
        };
        defer refreshed.deinit(allocator);

        try state.upsertMachine(allocator, refreshed.value, null);
        try printMachineRow(stdout, refreshed.value);
    }
}

fn handleStatus(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: StatusCommand,
) !void {
    if (command.machine_name == null) {
        return handleList(allocator, stdout, stderr, .{ .format = command.format });
    }

    return handleInspect(allocator, stdout, stderr, .{
        .machine_name = command.machine_name.?,
        .format = command.format,
    });
}

fn handleInspect(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: MachineCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine = state.findMachine(&loaded_state.value, command.machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] use `rove list` to inspect tracked machines\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    };

    var refreshed = refreshMachineFromProvider(allocator, machine.*) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to refresh machine '{s}': {s}\n",
            .{ command.machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };
    defer refreshed.deinit(allocator);

    try state.upsertMachine(allocator, refreshed.value, null);

    if (command.format == .json) {
        try writeMachineJsonDocument(allocator, stdout, refreshed.value);
        return;
    }

    try stdout.writeAll("NAME\tTARGET\tPROVIDER\tSTATUS\tREMOTE\tSSH\tREGION\n");
    try printMachineRow(stdout, refreshed.value);
}

fn printMachineRow(stdout: anytype, machine: model.MachineRecord) !void {
    try std.fmt.format(
        stdout,
        "{s}\t{s}\t{s}\t{s}\t{s}\t",
        .{
            machine.name,
            machine.target_name orelse machine.name,
            model.providerName(machine.provider),
            model.statusName(machine.status),
            machine.remote_state orelse "-",
        },
    );
    try printSshEndpoint(stdout, machine);
    try std.fmt.format(stdout, "\t{s}\n", .{machine.region orelse "-"});
}

fn printSshEndpoint(stdout: anytype, machine: model.MachineRecord) !void {
    const configured_host = model.configuredSshHost(machine);
    const endpoint_host = model.endpointSshHost(machine);
    if (machine.ssh_resolved_host != null and !std.mem.eql(u8, configured_host, endpoint_host)) {
        try std.fmt.format(stdout, "{s}->{s}:{d}", .{ configured_host, endpoint_host, machine.ssh_port });
        return;
    }

    if (machine.ssh_resolver != .system) {
        try std.fmt.format(
            stdout,
            "{s}:{d}[{s}]",
            .{ configured_host, machine.ssh_port, model.sshResolverName(machine.ssh_resolver) },
        );
        return;
    }

    try std.fmt.format(stdout, "{s}:{d}", .{ configured_host, machine.ssh_port });
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
        if (command.format == .json) {
            try stdout.writeAll("{\"results\":[],\"machines\":[]}\n");
            return;
        }

        try stdout.writeAll(
            "[info] no tracked machines\n" ++
                "[hint] use `rove up <target>` or `rove adopt <target> <machine-id>` first\n",
        );
        return;
    }

    if (command.format == .json) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        try out.writer.writeAll("{\"results\":[");
        var emitted: usize = 0;

        if (command.machine_name) |machine_name| {
            const machine = state.findMachine(&loaded_state.value, machine_name) orelse {
                try std.fmt.format(
                    stderr,
                    "[error] no tracked machine named '{s}'\n" ++
                        "[hint] use `rove list` to inspect tracked machines\n",
                    .{machine_name},
                );
                return error.HandledFailure;
            };

            var report = refreshMachineForReport(allocator, stderr, machine.*, command.prune_missing) catch |err| switch (err) {
                error.HandledFailure => return error.HandledFailure,
                else => return err,
            };
            defer report.deinit(allocator);

            try appendRefreshResultJson(&out, report);
            emitted += 1;
        } else {
            for (loaded_state.value.machines) |machine| {
                var report = refreshMachineForReport(allocator, stderr, machine, command.prune_missing) catch |err| switch (err) {
                    error.HandledFailure => continue,
                    else => return err,
                };
                defer report.deinit(allocator);

                if (emitted > 0) try out.writer.writeByte(',');
                try appendRefreshResultJson(&out, report);
                emitted += 1;
            }
        }

        try out.writer.writeAll("],\"machines\":[");
        var reloaded = try state.loadOrEmpty(allocator, null);
        defer reloaded.deinit();

        for (reloaded.value.machines, 0..) |machine, index| {
            if (index > 0) try out.writer.writeByte(',');
            try appendMachineJson(&out, machine);
        }

        try out.writer.writeAll("]}\n");
        try stdout.writeAll(out.written());
        return;
    }

    try stdout.writeAll("NAME\tRESULT\tSTATUS\tREMOTE\tSSH\n");

    if (command.machine_name) |machine_name| {
        const machine = state.findMachine(&loaded_state.value, machine_name) orelse {
            try std.fmt.format(
                stderr,
                "[error] no tracked machine named '{s}'\n" ++
                    "[hint] use `rove list` to inspect tracked machines\n",
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

    const config_path = try config.resolveConfigPath(allocator, null);
    defer allocator.free(config_path);

    var has_errors = false;
    var loaded_config = config.load(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => {
            has_errors = true;
            const detail = try std.fmt.allocPrint(allocator, "missing {s}", .{config_path});
            defer allocator.free(detail);
            try printDoctorRow(stdout, "config", "error", detail);
            return error.HandledFailure;
        },
        else => return err,
    };
    defer loaded_config.deinit();

    const loaded_detail = try std.fmt.allocPrint(allocator, "loaded {s}", .{config_path});
    defer allocator.free(loaded_detail);
    try printDoctorRow(stdout, "config", "ok", loaded_detail);

    const provider_count = @typeInfo(model.ProviderKind).@"enum".fields.len;
    var checked_providers = [_]bool{false} ** provider_count;

    for (loaded_config.value.targets) |target| {
        const provider_index: usize = @intFromEnum(target.provider);
        if (!checked_providers[provider_index]) {
            checked_providers[provider_index] = true;
            for (provider.doctorChecks(target.provider)) |check| {
                doctorExecCheck(allocator, stdout, check.name, check.argv, check.ok_detail, &has_errors);
            }
        }

        const summary = provider.targetSummary(target);
        if (summary.image) |image_ref| {
            const detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{
                target.name,
                if (isPinnedImageRef(image_ref)) "pinned image ref" else "unpinned image ref",
            });
            defer allocator.free(detail);

            try printDoctorRow(stdout, "image", if (isPinnedImageRef(image_ref)) "ok" else "warn", detail);
        }
    }

    const managed_key = keys.ensureManagedKeyPair(allocator) catch |err| {
        has_errors = true;
        try printDoctorRow(stdout, "machine ssh key", "error", @errorName(err));
        return error.HandledFailure;
    };
    defer managed_key.deinit(allocator);
    try printDoctorRow(stdout, "machine ssh key", "ok", "managed machine SSH key is present");

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

fn handleAdopt(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: AdoptCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const config_path = try config.resolveConfigPath(allocator, null);
    defer allocator.free(config_path);

    var loaded_config = config.load(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => {
            const lookup = try config.configLookupDescription(allocator);
            defer allocator.free(lookup);
            try std.fmt.format(
                stderr,
                "[error] missing config file '{s}'\n" ++
                    "[hint] create it before adopting a target\n" ++
                    "[hint] lookup order: {s}\n",
                .{ config_path, lookup },
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
                .{ command.target, config_path },
            );
            return error.HandledFailure;
        },
        else => return err,
    };

    if (state.findMachineById(&loaded_state.value, command.machine_id)) |existing| {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' is already tracked as '{s}'\n" ++
                "[hint] use `rove refresh {s}` or `rove status {s}` to inspect it\n",
            .{ command.machine_id, existing.name, existing.name, existing.name },
        );
        return error.HandledFailure;
    }

    const target_provider_config = providerConfigForTarget(target.*);
    const inspected = try provider.inspect(allocator, target.provider, .{
        .provider_config = target_provider_config,
        .machine_id = command.machine_id,
        .instance_name = command.name,
    });
    defer inspected.deinit(allocator);

    if (!inspected.exists) {
        try std.fmt.format(
            stderr,
            "[error] machine '{s}' was not found for target '{s}'\n",
            .{ command.machine_id, target.name },
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

    const fallback_host = try provider.fallbackHost(allocator, target_provider_config);
    defer {
        if (fallback_host) |host| allocator.free(host);
    }

    const adopted_host = inspected.host orelse fallback_host orelse {
        try std.fmt.format(
            stderr,
            "[error] provider did not return an SSH host for machine '{s}'\n",
            .{command.machine_id},
        );
        return error.HandledFailure;
    };

    const summary = provider.targetSummary(target.*);

    const machine = model.MachineRecord{
        .name = adopted_name,
        .target_name = target.name,
        .provider = target.provider,
        .id = command.machine_id,
        .machine_name = inspected.machine_name,
        .provider_scope = provider.scopeForConfig(target_provider_config),
        .app = provider.legacyAppAliasForConfig(target_provider_config),
        .host = adopted_host,
        .ssh_configured_host = adopted_host,
        .ssh_port = inspected.ssh_port orelse 22,
        .ssh_resolver = target.ssh_resolver,
        .require_private_ssh = target.require_private_ssh,
        .ssh_identity_file = target.ssh_identity_file,
        .region = inspected.region,
        .remote_state = inspected.remote_state,
        .ssh_user = target.ssh_user,
        .status = lifecycleFromRemoteState(inspected.remote_state, .provisioned),
    };

    try state.upsertMachine(allocator, machine, null);

    if (command.format == .json) {
        try writeMachineJsonDocument(allocator, stdout, machine);
        return;
    }

    try std.fmt.format(
        stdout,
        "[info] adopted machine '{s}' as instance '{s}'\n" ++
            "[info] target: {s}\n" ++
            "[info] provider: {s}\n" ++
            "[info] {s}: {s}\n" ++
            "[info] ssh: {s}@{s}:{d}\n" ++
            "[info] remote_state: {s}\n",
        .{
            command.machine_id,
            adopted_name,
            target.name,
            model.providerName(target.provider),
            summary.scope_label,
            summary.scope orelse "-",
            machine.ssh_user,
            machine.host,
            machine.ssh_port,
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
    const launch_started_ms = std.time.milliTimestamp();
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
                "[hint] use `rove status {s}` to inspect it or `rove down {s}` before creating another\n",
            .{ instance_name, instance_name, instance_name },
        );
        return error.HandledFailure;
    }

    const config_path = try config.resolveConfigPath(allocator, null);
    defer allocator.free(config_path);

    var loaded_config = config.load(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => {
            const lookup = try config.configLookupDescription(allocator);
            defer allocator.free(lookup);
            try std.fmt.format(
                stderr,
                "[error] missing config file '{s}'\n" ++
                    "[hint] create it before running a target\n" ++
                    "[hint] lookup order: {s}\n",
                .{ config_path, lookup },
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
                .{ command.target, config_path },
            );
            return error.HandledFailure;
        },
        else => return err,
    };

    const target_provider_config = providerConfigForTarget(target.*);
    const summary = provider.targetSummary(target.*);
    const placement = try provider.renderPlacementSummary(allocator, target.*);
    defer allocator.free(placement);
    const progress = LaunchProgressContext{
        .enabled = command.progress_jsonl,
        .started_ms = launch_started_ms,
        .instance_name = instance_name,
        .target_name = target.name,
        .provider = target.provider,
    };

    try emitLaunchProgress(allocator, stderr, progress, "launch", "requested", null);

    var create_authorized_key: ?[]u8 = null;
    defer if (create_authorized_key) |authorized_key| allocator.free(authorized_key);
    if (target.ssh_identity_file) |ssh_identity_file| {
        const expanded_identity_file = try paths.expandUserPath(allocator, ssh_identity_file);
        defer allocator.free(expanded_identity_file);
        create_authorized_key = try keys.publicKeyForPrivateKey(allocator, expanded_identity_file);
    }

    try emitLaunchProgress(allocator, stderr, progress, "provider_create", "started", null);
    const created = provider.create(allocator, target.provider, .{
        .target_name = target.name,
        .provider_config = target_provider_config,
        .instance_name = instance_name,
        .authorized_key = create_authorized_key,
    }) catch |err| {
        try emitLaunchProgress(allocator, stderr, progress, "provider_create", "failed", null);
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
        .provider_scope = provider.scopeForConfig(target_provider_config),
        .app = provider.legacyAppAliasForConfig(target_provider_config),
        .host = created.host,
        .ssh_configured_host = created.host,
        .ssh_port = created.ssh_port,
        .ssh_resolver = target.ssh_resolver,
        .require_private_ssh = target.require_private_ssh,
        .ssh_identity_file = target.ssh_identity_file,
        .region = created.region,
        .ssh_user = target.ssh_user,
        .status = .provisioned,
    };

    try state.upsertMachine(allocator, machine, null);
    try emitLaunchProgress(allocator, stderr, progress, "provider_create", "done", machine);

    if (command.format == .human) {
        try std.fmt.format(
            stdout,
            "[info] instance '{s}' created from target '{s}'\n" ++
                "[info] provider: {s}\n" ++
                "[info] {s}: {s}\n" ++
                "[info] machine_id: {s}\n" ++
                "[info] image: {s}\n" ++
                "[info] {s}: {s}\n" ++
                "[info] placement: {s}\n" ++
                "[info] ssh: {s}@{s}:{d}\n",
            .{
                machine.name,
                target.name,
                model.providerName(target.provider),
                summary.scope_label,
                summary.scope orelse "-",
                created.machine_id,
                summary.image orelse "-",
                summary.size_label,
                summary.size orelse "-",
                placement,
                machine.ssh_user,
                created.host,
                created.ssh_port,
            },
        );
    }

    machine.status = .waiting_for_ssh;
    try state.upsertMachine(allocator, machine, null);
    try emitLaunchProgress(allocator, stderr, progress, "ssh_wait", "started", machine);

    if (command.format == .human) {
        try std.fmt.format(
            stdout,
            "[info] waiting for SSH on {s}@{s}:{d}\n",
            .{ machine.ssh_user, machine.host, machine.ssh_port },
        );
    }

    const ready = ssh.waitForReady(allocator, machine, .{}) catch |err| {
        machine.status = .provisioned_unreachable;
        try state.upsertMachine(allocator, machine, null);
        try emitLaunchProgress(allocator, stderr, progress, "ssh_wait", "failed", machine);

        try std.fmt.format(
            stderr,
            "[error] ssh did not become ready for instance '{s}': {s}\n" ++
                "[hint] inspect the machine with `rove status {s}` or `rove ssh {s}` once access works\n",
            .{ machine.name, @errorName(err), machine.name, machine.name },
        );
        return error.HandledFailure;
    };
    defer ready.deinit(allocator);

    if (ready.endpoint) |endpoint| {
        endpoint.applyToMachine(&machine);
        try state.upsertMachine(allocator, machine, null);
        if (machine.ssh_resolved_host != null) {
            try emitLaunchProgress(allocator, stderr, progress, "endpoint_resolution", "done", machine);
        }
    }

    try emitLaunchProgress(allocator, stderr, progress, "ssh", "ready", machine);
    try state.upsertMachine(allocator, machine, null);

    if (target.startup_script) |startup_script| {
        machine.status = .bootstrapping;
        try state.upsertMachine(allocator, machine, null);
        try emitLaunchProgress(allocator, stderr, progress, "bootstrap", "started", machine);

        if (command.format == .human) {
            try std.fmt.format(
                stdout,
                "[info] SSH ready\n" ++
                    "[info] running bootstrap script: {s}\n",
                .{startup_script},
            );
        }

        bootstrap.run(allocator, machine, startup_script) catch |err| {
            machine.status = .bootstrap_failed;
            try state.upsertMachine(allocator, machine, null);
            try emitLaunchProgress(allocator, stderr, progress, "bootstrap", "failed", machine);

            try std.fmt.format(
                stderr,
                "[error] bootstrap failed for instance '{s}': {s}\n" ++
                    "[hint] the machine is still running; use `rove ssh {s}` to inspect it\n",
                .{ machine.name, @errorName(err), machine.name },
            );
            return error.HandledFailure;
        };
        try emitLaunchProgress(allocator, stderr, progress, "bootstrap", "done", machine);
    } else if (command.format == .human) {
        try stdout.writeAll("[info] SSH ready\n");
        try emitLaunchProgress(allocator, stderr, progress, "bootstrap", "skipped", machine);
    } else {
        try emitLaunchProgress(allocator, stderr, progress, "bootstrap", "skipped", machine);
    }

    if (target.readiness_command) |readiness_command| {
        machine.status = .checking_readiness;
        try state.upsertMachine(allocator, machine, null);
        try emitLaunchProgress(allocator, stderr, progress, "readiness_command", "started", machine);

        if (command.format == .human) {
            try stdout.writeAll("[info] waiting for readiness command\n");
        }

        ssh.waitForCommand(allocator, machine, readiness_command, readinessWaitOptions(target.*)) catch |err| {
            machine.status = .readiness_failed;
            try state.upsertMachine(allocator, machine, null);
            try emitLaunchProgress(allocator, stderr, progress, "readiness_command", "failed", machine);

            try std.fmt.format(
                stderr,
                "[error] readiness command did not succeed for instance '{s}': {s}\n" ++
                    "[hint] the machine is still running; use `rove ssh {s}` to inspect it\n",
                .{ machine.name, @errorName(err), machine.name },
            );
            return error.HandledFailure;
        };

        if (command.format == .human) {
            try stdout.writeAll("[info] readiness command succeeded\n");
        }
        try emitLaunchProgress(allocator, stderr, progress, "readiness_command", "done", machine);
    } else {
        try emitLaunchProgress(allocator, stderr, progress, "readiness_command", "skipped", machine);
    }

    machine.status = .ready;
    try state.upsertMachine(allocator, machine, null);
    try emitLaunchProgress(allocator, stderr, progress, "ready", "done", machine);

    if (command.format == .json) {
        try writeMachineJsonDocument(allocator, stdout, machine);
        return;
    }

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
    machine_name: []const u8,
) !void {
    _ = stdout;

    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine = state.findMachine(&loaded_state.value, machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so SSH knows where to connect\n",
            .{machine_name},
        );
        return error.HandledFailure;
    };

    if (machine.status == .destroying) {
        try std.fmt.format(stderr, "[error] machine '{s}' is being destroyed\n", .{machine_name});
        return error.HandledFailure;
    }

    var resolved_machine = resolveMachineEndpointForUse(allocator, machine.*) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] ssh resolver '{s}' failed for machine '{s}' host '{s}': {s}\n",
            .{
                model.sshResolverName(machine.ssh_resolver),
                machine_name,
                model.configuredSshHost(machine.*),
                @errorName(err),
            },
        );
        if (machine.require_private_ssh) {
            try stderr.writeAll("[hint] private SSH is required; no system or public SSH fallback was attempted\n");
        }
        return error.HandledFailure;
    };
    defer resolved_machine.deinit(allocator);
    try state.upsertMachine(allocator, resolved_machine.value, null);

    const term = ssh.openInteractive(allocator, resolved_machine.value) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to start ssh for machine '{s}': {s}\n",
            .{ machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                try std.fmt.format(stderr, "[error] ssh exited with code {d}\n", .{code});
                return error.HandledFailure;
            }
        },
        else => {
            try stderr.writeAll("[error] ssh ended unexpectedly\n");
            return error.HandledFailure;
        },
    }
}

fn handleExec(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: ExecCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine = state.findMachine(&loaded_state.value, command.machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] run a target first so there is a machine to execute on\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    };

    if (machine.status == .destroying) {
        try std.fmt.format(stderr, "[error] machine '{s}' is being destroyed\n", .{command.machine_name});
        return error.HandledFailure;
    }

    const remote_command = try renderRemoteCommand(allocator, command.argv);
    defer allocator.free(remote_command);

    var resolved_machine = resolveMachineEndpointForUse(allocator, machine.*) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] ssh resolver '{s}' failed for machine '{s}' host '{s}': {s}\n",
            .{
                model.sshResolverName(machine.ssh_resolver),
                command.machine_name,
                model.configuredSshHost(machine.*),
                @errorName(err),
            },
        );
        if (machine.require_private_ssh) {
            try stderr.writeAll("[hint] private SSH is required; no system or public SSH fallback was attempted\n");
        }
        return error.HandledFailure;
    };
    defer resolved_machine.deinit(allocator);
    try state.upsertMachine(allocator, resolved_machine.value, null);

    const result = ssh.runBatchCommand(allocator, resolved_machine.value, remote_command) catch |err| {
        try std.fmt.format(
            stderr,
            "[error] failed to execute command on machine '{s}': {s}\n",
            .{ command.machine_name, @errorName(err) },
        );
        return error.HandledFailure;
    };
    defer result.deinit(allocator);

    if (result.stdout.len > 0) try stdout.writeAll(result.stdout);
    if (result.stderr.len > 0) try stderr.writeAll(result.stderr);

    if (!result.succeeded()) {
        switch (result.term) {
            .Exited => |code| try std.fmt.format(stderr, "[error] remote command exited with code {d}\n", .{code}),
            else => try stderr.writeAll("[error] remote command ended unexpectedly\n"),
        }
        return error.HandledFailure;
    }
}

fn handleDown(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    command: MachineCommand,
) !void {
    var loaded_state = try state.loadOrEmpty(allocator, null);
    defer loaded_state.deinit();

    const machine = state.findMachine(&loaded_state.value, command.machine_name) orelse {
        try std.fmt.format(
            stderr,
            "[error] no tracked machine named '{s}'\n" ++
                "[hint] nothing to destroy until a machine has been run at least once\n",
            .{command.machine_name},
        );
        return error.HandledFailure;
    };

    var destroying = machine.*;
    destroying.status = .destroying;
    try state.upsertMachine(allocator, destroying, null);

    const machine_provider_config = providerConfigForMachine(machine.*) catch |err| switch (err) {
        error.MissingProviderScope => {
            try std.fmt.format(stderr, "[error] tracked machine '{s}' is missing provider scope metadata\n", .{command.machine_name});
            return error.HandledFailure;
        },
        else => return err,
    };

    provider.destroy(allocator, machine.provider, .{
        .provider_config = machine_provider_config,
        .machine_id = machine.id,
    }) catch |err| {
        try std.fmt.format(stderr, "[error] failed to destroy machine '{s}': {s}\n", .{ command.machine_name, @errorName(err) });
        return error.HandledFailure;
    };

    _ = try state.removeMachine(allocator, command.machine_name, null);

    if (command.format == .json) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        try out.writer.writeAll("{\"destroyed\":true,\"machine\":");
        try appendMachineJson(&out, machine.*);
        try out.writer.writeAll("}\n");
        try stdout.writeAll(out.written());
        return;
    }

    try std.fmt.format(
        stdout,
        "[info] machine '{s}' destroyed\n" ++
            "[info] machine_id: {s}\n" ++
            "[hint] local state has been cleared\n",
        .{ command.machine_name, machine.id },
    );
}

fn renderRemoteCommand(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    for (argv, 0..) |part, index| {
        if (index > 0) try writer.writer.writeByte(' ');
        const quoted = try shell.quote(allocator, part);
        defer allocator.free(quoted);
        try writer.writer.writeAll(quoted);
    }

    return allocator.dupe(u8, writer.written());
}

fn readinessWaitOptions(target: model.TargetConfig) ssh.WaitOptions {
    return .{
        .timeout_ms = target.readiness_timeout_ms orelse 180 * std.time.ms_per_s,
        .poll_interval_ms = target.readiness_poll_interval_ms orelse 2 * std.time.ms_per_s,
    };
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

const EndpointResolvedMachine = struct {
    value: model.MachineRecord,
    endpoint: ssh.EndpointMetadata,

    fn deinit(self: EndpointResolvedMachine, allocator: std.mem.Allocator) void {
        self.endpoint.deinit(allocator);
    }
};

const RefreshReport = struct {
    refreshed: RefreshedMachine,
    result: []const u8,
    pruned: bool = false,

    fn deinit(self: RefreshReport, allocator: std.mem.Allocator) void {
        self.refreshed.deinit(allocator);
    }
};

fn resolveMachineEndpointForUse(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !EndpointResolvedMachine {
    const endpoint = try ssh.resolveEndpointMetadata(allocator, machine);
    var resolved = machine;
    endpoint.applyToMachine(&resolved);
    return .{
        .value = resolved,
        .endpoint = endpoint,
    };
}

fn refreshMachineFromProvider(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !RefreshedMachine {
    var refreshed = RefreshedMachine{ .value = machine };
    if (refreshed.value.ssh_configured_host == null) {
        refreshed.value.ssh_configured_host = refreshed.value.host;
    }

    const machine_provider_config = providerConfigForMachine(machine) catch {
        refreshed.value.remote_state = "unknown";
        return refreshed;
    };

    const inspected = try provider.inspect(allocator, machine.provider, .{
        .provider_config = machine_provider_config,
        .machine_id = machine.id,
        .instance_name = machine.name,
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
        const previous_configured_host = model.configuredSshHost(refreshed.value);
        refreshed.value.host = host;
        refreshed.value.ssh_configured_host = host;
        if (!std.mem.eql(u8, previous_configured_host, host)) {
            refreshed.value.ssh_resolved_host = null;
        }
        refreshed.owned_host = host;
    }
    if (inspected.ssh_port) |ssh_port| {
        refreshed.value.ssh_port = ssh_port;
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

fn refreshMachineForReport(
    allocator: std.mem.Allocator,
    stderr: anytype,
    machine: model.MachineRecord,
    prune_missing: bool,
) !RefreshReport {
    var refreshed = refreshMachineFromProvider(allocator, machine) catch |err| {
        try std.fmt.format(
            stderr,
            "[warn] failed to refresh machine '{s}': {s}\n",
            .{ machine.name, @errorName(err) },
        );
        return error.HandledFailure;
    };
    errdefer refreshed.deinit(allocator);

    if (prune_missing and refreshed.missing) {
        _ = try state.removeMachine(allocator, machine.name, null);
        return .{
            .refreshed = refreshed,
            .result = "pruned",
            .pruned = true,
        };
    }

    try state.upsertMachine(allocator, refreshed.value, null);

    return .{
        .refreshed = refreshed,
        .result = if (refreshed.missing) "missing" else "updated",
    };
}

fn refreshAndReportMachine(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    machine: model.MachineRecord,
    prune_missing: bool,
) !void {
    const report = try refreshMachineForReport(allocator, stderr, machine, prune_missing);
    defer report.deinit(allocator);

    if (report.pruned) {
        try std.fmt.format(
            stdout,
            "{s}\tpruned\t{s}\tmissing\t-\n",
            .{ machine.name, model.statusName(report.refreshed.value.status) },
        );
        return;
    }

    try std.fmt.format(
        stdout,
        "{s}\t{s}\t{s}\t{s}\t",
        .{
            machine.name,
            report.result,
            model.statusName(report.refreshed.value.status),
            report.refreshed.value.remote_state orelse "-",
        },
    );
    try printSshEndpoint(stdout, report.refreshed.value);
    try stdout.writeAll("\n");
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

    var resolved_machine = resolveMachineEndpointForUse(allocator, refreshed.value) catch |err| {
        has_errors.* = true;
        const detail = try std.fmt.allocPrint(
            allocator,
            "{s}: ssh resolver {s} failed for {s}: {s}",
            .{
                machine.name,
                model.sshResolverName(refreshed.value.ssh_resolver),
                model.configuredSshHost(refreshed.value),
                @errorName(err),
            },
        );
        defer allocator.free(detail);
        try printDoctorRow(stdout, "ssh", "error", detail);
        return;
    };
    defer resolved_machine.deinit(allocator);
    try state.upsertMachine(allocator, resolved_machine.value, null);

    ssh.preflight(allocator, resolved_machine.value) catch |err| {
        has_errors.* = true;
        const detail = try std.fmt.allocPrint(allocator, "{s}: ssh preflight failed: {s}", .{ machine.name, @errorName(err) });
        defer allocator.free(detail);
        try printDoctorRow(stdout, "ssh", "error", detail);
        return;
    };

    const ssh_detail = try std.fmt.allocPrint(allocator, "{s}: SSH is reachable on {s}:{d}", .{
        machine.name,
        model.endpointSshHost(resolved_machine.value),
        resolved_machine.value.ssh_port,
    });
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
        const trimmed = std.mem.trim(u8, result.stderr, "\r\n\t ");
        const detail = if (trimmed.len > 0)
            std.fmt.allocPrint(allocator, "{s}: {s}", .{ check_name, trimmed }) catch return
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

fn providerConfigForTarget(target: model.TargetConfig) provider.ProviderTargetConfig {
    return switch (target.provider) {
        .fly => .{ .fly = config.resolveFlyTarget(target) },
        .vast => .{ .vast = config.resolveVastTarget(target) },
    };
}

fn providerConfigForMachine(machine: model.MachineRecord) !provider.ProviderTargetConfig {
    return switch (machine.provider) {
        .fly => .{ .fly = .{
            .app = machine.provider_scope orelse machine.app orelse return error.MissingProviderScope,
            .ssh_host = model.configuredSshHost(machine),
            .ssh_port = machine.ssh_port,
        } },
        .vast => .{ .vast = .{} },
    };
}

fn lifecycleFromRemoteState(
    remote_state: ?[]const u8,
    fallback: model.LifecycleStatus,
) model.LifecycleStatus {
    const value = remote_state orelse return fallback;

    if (std.ascii.eqlIgnoreCase(value, "started") or
        std.ascii.eqlIgnoreCase(value, "running") or
        std.ascii.eqlIgnoreCase(value, "frozen"))
    {
        if (fallback == .checking_readiness or fallback == .readiness_failed) {
            return fallback;
        }
        return .ready;
    }

    if (std.ascii.eqlIgnoreCase(value, "created") or
        std.ascii.eqlIgnoreCase(value, "starting") or
        std.ascii.eqlIgnoreCase(value, "pending") or
        std.ascii.eqlIgnoreCase(value, "loading") or
        std.ascii.eqlIgnoreCase(value, "rebooting"))
    {
        return .provisioned;
    }

    if (std.ascii.eqlIgnoreCase(value, "stopped") or
        std.ascii.eqlIgnoreCase(value, "suspended") or
        std.ascii.eqlIgnoreCase(value, "exited") or
        std.ascii.eqlIgnoreCase(value, "offline") or
        std.ascii.eqlIgnoreCase(value, "unknown") or
        std.ascii.eqlIgnoreCase(value, "unloaded") or
        std.ascii.eqlIgnoreCase(value, "terminated") or
        std.ascii.eqlIgnoreCase(value, "failed") or
        std.ascii.eqlIgnoreCase(value, "destroyed") or
        std.ascii.eqlIgnoreCase(value, "missing"))
    {
        return .provisioned_unreachable;
    }

    return fallback;
}

test "remote running states preserve readiness lifecycle during refresh" {
    const running_states = [_][]const u8{ "started", "running", "frozen" };

    for (running_states) |remote_state| {
        try std.testing.expectEqual(
            model.LifecycleStatus.checking_readiness,
            lifecycleFromRemoteState(remote_state, .checking_readiness),
        );
        try std.testing.expectEqual(
            model.LifecycleStatus.readiness_failed,
            lifecycleFromRemoteState(remote_state, .readiness_failed),
        );
        try std.testing.expectEqual(
            model.LifecycleStatus.ready,
            lifecycleFromRemoteState(remote_state, .provisioned),
        );
    }
}

fn isValidInstanceName(name: []const u8) bool {
    if (name.len == 0) return false;

    for (name) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.') continue;
        return false;
    }

    return true;
}

test "parse up target with explicit name and json" {
    const command = try parse(&.{ "up", "devbox", "--json", "--name", "work", "--progress-jsonl" });

    switch (command) {
        .up => |run_command| {
            try std.testing.expectEqualStrings("devbox", run_command.target);
            try std.testing.expectEqualStrings("work", run_command.name.?);
            try std.testing.expectEqual(OutputFormat.json, run_command.format);
            try std.testing.expect(run_command.progress_jsonl);
        },
        else => return error.InvalidArguments,
    }
}

test "reject duplicate launch progress flag" {
    try std.testing.expectError(
        error.InvalidArguments,
        parse(&.{ "up", "devbox", "--progress-jsonl", "--progress-jsonl" }),
    );
}

test "parse run alias" {
    const command = try parse(&.{ "run", "devbox" });

    switch (command) {
        .run => |run_command| try std.testing.expectEqualStrings("devbox", run_command.target),
        else => return error.InvalidArguments,
    }
}

test "parse status target" {
    const command = try parse(&.{ "status", "work", "--json" });

    switch (command) {
        .status => |status_command| {
            try std.testing.expectEqualStrings("work", status_command.machine_name.?);
            try std.testing.expectEqual(OutputFormat.json, status_command.format);
        },
        else => return error.InvalidArguments,
    }
}

test "parse inspect target" {
    const command = try parse(&.{ "inspect", "work", "--json" });

    switch (command) {
        .inspect => |machine_command| {
            try std.testing.expectEqualStrings("work", machine_command.machine_name);
            try std.testing.expectEqual(OutputFormat.json, machine_command.format);
        },
        else => return error.InvalidArguments,
    }
}

test "parse refresh all with prune and json" {
    const command = try parse(&.{ "refresh", "--prune-missing", "--json" });

    switch (command) {
        .refresh => |refresh_command| {
            try std.testing.expect(refresh_command.machine_name == null);
            try std.testing.expect(refresh_command.prune_missing);
            try std.testing.expectEqual(OutputFormat.json, refresh_command.format);
        },
        else => return error.InvalidArguments,
    }
}

test "parse adopt target with json" {
    const command = try parse(&.{ "adopt", "devbox", "machine-123", "--json", "--name", "recovered" });

    switch (command) {
        .adopt => |adopt_command| {
            try std.testing.expectEqualStrings("devbox", adopt_command.target);
            try std.testing.expectEqualStrings("machine-123", adopt_command.machine_id);
            try std.testing.expectEqualStrings("recovered", adopt_command.name.?);
            try std.testing.expectEqual(OutputFormat.json, adopt_command.format);
        },
        else => return error.InvalidArguments,
    }
}

test "parse down with json" {
    const command = try parse(&.{ "down", "work", "--json" });

    switch (command) {
        .down => |machine_command| {
            try std.testing.expectEqualStrings("work", machine_command.machine_name);
            try std.testing.expectEqual(OutputFormat.json, machine_command.format);
        },
        else => return error.InvalidArguments,
    }
}

test "parse exec command" {
    const command = try parse(&.{ "exec", "work", "--", "uname", "-a" });

    switch (command) {
        .exec => |exec_command| {
            try std.testing.expectEqualStrings("work", exec_command.machine_name);
            try std.testing.expectEqual(@as(usize, 2), exec_command.argv.len);
            try std.testing.expectEqualStrings("uname", exec_command.argv[0]);
        },
        else => return error.InvalidArguments,
    }
}

test "render remote command quotes argv" {
    const allocator = std.testing.allocator;
    const rendered = try renderRemoteCommand(allocator, &.{ "sh", "-lc", "echo hello && pwd" });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("'sh' '-lc' 'echo hello && pwd'", rendered);
}

test "render launch progress event json line" {
    const allocator = std.testing.allocator;
    const progress = LaunchProgressContext{
        .enabled = true,
        .started_ms = std.time.milliTimestamp(),
        .instance_name = "work",
        .target_name = "devbox",
        .provider = .fly,
    };
    const machine = model.MachineRecord{
        .name = "work",
        .target_name = "devbox",
        .provider = .fly,
        .id = "machine-id",
        .machine_name = "rove-work-1234",
        .host = "private-work",
        .ssh_configured_host = "private-work",
        .ssh_resolved_host = "100.64.1.2",
        .ssh_port = 2222,
        .ssh_resolver = .tailscale,
        .require_private_ssh = true,
        .ssh_user = "rove",
        .status = .waiting_for_ssh,
    };

    const line = try renderLaunchProgressEvent(allocator, progress, "endpoint_resolution", "done", machine);
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const object = parsed.value.object;

    try std.testing.expectEqualStrings("launch_progress", object.get("type").?.string);
    try std.testing.expectEqualStrings("endpoint_resolution", object.get("phase").?.string);
    try std.testing.expectEqualStrings("done", object.get("status").?.string);
    try std.testing.expectEqualStrings("work", object.get("instance_name").?.string);
    try std.testing.expectEqualStrings("devbox", object.get("target_name").?.string);
    try std.testing.expectEqualStrings("fly", object.get("provider").?.string);
    try std.testing.expectEqualStrings("machine-id", object.get("machine_id").?.string);
    try std.testing.expectEqualStrings("private-work", object.get("ssh_configured_host").?.string);
    try std.testing.expectEqualStrings("100.64.1.2", object.get("ssh_resolved_host").?.string);
    try std.testing.expectEqualStrings("100.64.1.2", object.get("ssh_endpoint_host").?.string);
    try std.testing.expectEqual(@as(i64, 2222), object.get("ssh_port").?.integer);
}
