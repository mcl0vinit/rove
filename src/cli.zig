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
        \\  rove up <target> [--name <name>] [--json]
        \\  rove run <target> [--name <name>] [--json]
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
        \\  config: ./rove.json
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
    try out.writer.writeAll(",\"region\":");
    try appendJsonNullableString(out, machine.region);
    try out.writer.writeAll(",\"remote_state\":");
    try appendJsonNullableString(out, machine.remote_state);
    try out.writer.writeAll(",\"ssh_user\":");
    try appendJsonString(out, machine.ssh_user);
    try out.writer.writeAll(",\"status\":");
    try appendJsonString(out, model.statusName(machine.status));
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

    try stdout.writeAll("NAME\tTARGET\tPROVIDER\tSTATUS\tREMOTE\tHOST\tREGION\n");
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

    try stdout.writeAll("NAME\tTARGET\tPROVIDER\tSTATUS\tREMOTE\tHOST\tREGION\n");
    try printMachineRow(stdout, refreshed.value);
}

fn printMachineRow(stdout: anytype, machine: model.MachineRecord) !void {
    try std.fmt.format(
        stdout,
        "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n",
        .{
            machine.name,
            machine.target_name orelse machine.name,
            model.providerName(machine.provider),
            model.statusName(machine.status),
            machine.remote_state orelse "-",
            machine.host,
            machine.region orelse "-",
        },
    );
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

    try stdout.writeAll("NAME\tRESULT\tSTATUS\tREMOTE\tHOST\n");

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
        const image_ref = switch (target.provider) {
            .fly => config.resolveFlyTarget(target).image,
        };
        const detail = try std.fmt.allocPrint(allocator, "{s}: {s}", .{
            target.name,
            if (isPinnedImageRef(image_ref)) "pinned image ref" else "unpinned image ref",
        });
        defer allocator.free(detail);

        try printDoctorRow(stdout, "image", if (isPinnedImageRef(image_ref)) "ok" else "warn", detail);
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
                "[hint] use `rove refresh {s}` or `rove status {s}` to inspect it\n",
            .{ command.machine_id, existing.name, existing.name, existing.name },
        );
        return error.HandledFailure;
    }

    const target_provider_config = providerConfigForTarget(target.*);
    const inspected = try provider.inspect(allocator, target.provider, .{
        .provider_config = target_provider_config,
        .machine_id = command.machine_id,
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

    const fly_config = target_provider_config.fly;
    const fallback_host = try std.fmt.allocPrint(allocator, "{s}.fly.dev", .{fly_config.app});
    defer allocator.free(fallback_host);

    const machine = model.MachineRecord{
        .name = adopted_name,
        .target_name = target.name,
        .provider = target.provider,
        .id = command.machine_id,
        .machine_name = inspected.machine_name,
        .provider_scope = fly_config.app,
        .app = fly_config.app,
        .host = inspected.host orelse fallback_host,
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
            "[info] app: {s}\n" ++
            "[info] host: {s}\n" ++
            "[info] remote_state: {s}\n",
        .{
            command.machine_id,
            adopted_name,
            target.name,
            model.providerName(target.provider),
            fly_config.app,
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
                "[hint] use `rove status {s}` to inspect it or `rove down {s}` before creating another\n",
            .{ instance_name, instance_name, instance_name },
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

    const target_provider_config = providerConfigForTarget(target.*);
    const fly_config = target_provider_config.fly;
    const placement = try renderPlacementSummary(allocator, target.*);
    defer allocator.free(placement);

    const created = provider.create(allocator, target.provider, .{
        .target_name = target.name,
        .provider_config = target_provider_config,
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
        .provider_scope = fly_config.app,
        .app = fly_config.app,
        .host = created.host,
        .region = created.region,
        .ssh_user = target.ssh_user,
        .status = .provisioned,
    };

    try state.upsertMachine(allocator, machine, null);

    if (command.format == .human) {
        try std.fmt.format(
            stdout,
            "[info] instance '{s}' created from target '{s}'\n" ++
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
                model.providerName(target.provider),
                fly_config.app,
                created.machine_id,
                fly_config.image,
                fly_config.vm_size,
                placement,
                created.host,
            },
        );
    }

    machine.status = .waiting_for_ssh;
    try state.upsertMachine(allocator, machine, null);

    if (command.format == .human) {
        try std.fmt.format(
            stdout,
            "[info] waiting for SSH on {s}@{s}\n",
            .{ machine.ssh_user, machine.host },
        );
    }

    ssh.waitForReady(allocator, machine, .{}) catch |err| {
        machine.status = .provisioned_unreachable;
        try state.upsertMachine(allocator, machine, null);

        try std.fmt.format(
            stderr,
            "[error] ssh did not become ready for instance '{s}': {s}\n" ++
                "[hint] inspect the machine with `rove status {s}` or `rove ssh {s}` once access works\n",
            .{ machine.name, @errorName(err), machine.name, machine.name },
        );
        return error.HandledFailure;
    };

    if (target.startup_script) |startup_script| {
        machine.status = .bootstrapping;
        try state.upsertMachine(allocator, machine, null);

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

            try std.fmt.format(
                stderr,
                "[error] bootstrap failed for instance '{s}': {s}\n" ++
                    "[hint] the machine is still running; use `rove ssh {s}` to inspect it\n",
                .{ machine.name, @errorName(err), machine.name },
            );
            return error.HandledFailure;
        };
    } else if (command.format == .human) {
        try stdout.writeAll("[info] SSH ready\n");
    }

    machine.status = .ready;
    try state.upsertMachine(allocator, machine, null);

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

    const term = ssh.openInteractive(allocator, machine.*) catch |err| {
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

    const result = ssh.runBatchCommand(allocator, machine.*, remote_command) catch |err| {
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

fn renderPlacementSummary(
    allocator: std.mem.Allocator,
    target: model.TargetConfig,
) ![]u8 {
    switch (target.provider) {
        .fly => {
            const fly_config = config.resolveFlyTarget(target);
            if (fly_config.region) |region| {
                return std.fmt.allocPrint(allocator, "fixed region {s}", .{region});
            }

            if (fly_config.region_preference) |preference| {
                const joined = try std.mem.join(allocator, ",", preference);
                defer allocator.free(joined);
                return std.fmt.allocPrint(allocator, "flexible preference {s}", .{joined});
            }
        },
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

const RefreshReport = struct {
    refreshed: RefreshedMachine,
    result: []const u8,
    pruned: bool = false,

    fn deinit(self: RefreshReport, allocator: std.mem.Allocator) void {
        self.refreshed.deinit(allocator);
    }
};

fn refreshMachineFromProvider(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !RefreshedMachine {
    var refreshed = RefreshedMachine{ .value = machine };

    const machine_provider_config = providerConfigForMachine(machine) catch {
        refreshed.value.remote_state = "unknown";
        return refreshed;
    };

    const inspected = try provider.inspect(allocator, machine.provider, .{
        .provider_config = machine_provider_config,
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
        "{s}\t{s}\t{s}\t{s}\t{s}\n",
        .{
            machine.name,
            report.result,
            model.statusName(report.refreshed.value.status),
            report.refreshed.value.remote_state orelse "-",
            report.refreshed.value.host,
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
    };
}

fn providerConfigForMachine(machine: model.MachineRecord) !provider.ProviderTargetConfig {
    return switch (machine.provider) {
        .fly => .{ .fly = .{
            .app = machine.provider_scope orelse machine.app orelse return error.MissingProviderScope,
        } },
    };
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

fn isValidInstanceName(name: []const u8) bool {
    if (name.len == 0) return false;

    for (name) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.') continue;
        return false;
    }

    return true;
}

test "parse up target with explicit name and json" {
    const command = try parse(&.{ "up", "devbox", "--json", "--name", "work" });

    switch (command) {
        .up => |run_command| {
            try std.testing.expectEqualStrings("devbox", run_command.target);
            try std.testing.expectEqualStrings("work", run_command.name.?);
            try std.testing.expectEqual(OutputFormat.json, run_command.format);
        },
        else => return error.InvalidArguments,
    }
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
