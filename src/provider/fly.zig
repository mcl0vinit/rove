const std = @import("std");
const exec = @import("../exec.zig");
const keys = @import("../keys.zig");
const model = @import("../model.zig");
const provider = @import("mod.zig");

pub fn create(
    allocator: std.mem.Allocator,
    request: provider.CreateRequest,
) !provider.CreateResult {
    const fly_config = request.provider_config.fly;
    const machine_name = try generatedMachineName(allocator, request.instance_name);
    defer allocator.free(machine_name);

    var managed_key: ?keys.ManagedKeyPair = null;
    defer if (managed_key) |key| key.deinit(allocator);
    var authorized_key: ?[]const u8 = null;
    if (fly_config.inject_authorized_keys) {
        authorized_key = request.authorized_key orelse blk: {
            managed_key = try keys.ensureManagedKeyPair(allocator);
            break :blk managed_key.?.public_key;
        };
    }

    var launch_args = try buildMachineRunArgs(
        allocator,
        fly_config,
        request.target_name,
        request.instance_name,
        machine_name,
        authorized_key,
    );
    defer launch_args.deinit(allocator);

    const run_result = try exec.run(allocator, launch_args.args.items);
    defer run_result.deinit(allocator);

    if (!run_result.succeeded()) {
        std.debug.print("[error] flyctl machine run failed\n{s}", .{run_result.stderr});
        return error.CommandFailed;
    }

    const machine = try lookupMachineByName(allocator, fly_config.app, machine_name);
    defer machine.deinit(allocator);

    return .{
        .machine_id = try allocator.dupe(u8, machine.id.?),
        .host = try renderSshHost(allocator, fly_config, request.instance_name, machine_name),
        .ssh_port = sshPortForConfig(fly_config),
        .region = if (machine.region) |region| try allocator.dupe(u8, region) else null,
        .machine_name = if (machine.name) |name| try allocator.dupe(u8, name) else null,
    };
}

pub fn destroy(
    allocator: std.mem.Allocator,
    request: provider.DestroyRequest,
) !void {
    const fly_config = request.provider_config.fly;
    const result = try exec.run(allocator, &.{
        "flyctl",
        "machine",
        "destroy",
        "--app",
        fly_config.app,
        "--force",
        request.machine_id,
    });
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        std.debug.print("[error] flyctl machine destroy failed\n{s}", .{result.stderr});
        return error.CommandFailed;
    }
}

pub fn inspect(
    allocator: std.mem.Allocator,
    request: provider.InspectRequest,
) !provider.InspectResult {
    const fly_config = request.provider_config.fly;
    const machine = try lookupMachineById(allocator, fly_config.app, request.machine_id);
    defer machine.deinit(allocator);

    if (!machine.exists) {
        return .{
            .exists = false,
        };
    }

    return .{
        .exists = true,
        .machine_name = if (machine.name) |name| try allocator.dupe(u8, name) else null,
        .host = try renderSshHost(allocator, fly_config, request.instance_name, machine.name),
        .ssh_port = sshPortForConfig(fly_config),
        .region = if (machine.region) |region| try allocator.dupe(u8, region) else null,
        .remote_state = if (machine.state) |state| try allocator.dupe(u8, state) else null,
    };
}

pub fn flyctlVersion(allocator: std.mem.Allocator) !exec.Result {
    return exec.run(allocator, &.{ "flyctl", "version" });
}

const ListedMachine = struct {
    id: []const u8,
    name: []const u8,
    state: ?[]const u8 = null,
    region: ?[]const u8 = null,
};

const FoundMachine = struct {
    exists: bool = true,
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    state: ?[]u8 = null,
    region: ?[]u8 = null,

    fn deinit(self: FoundMachine, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        if (self.name) |name| allocator.free(name);
        if (self.state) |state| allocator.free(state);
        if (self.region) |region| allocator.free(region);
    }
};

const MachineRunArgs = struct {
    args: std.ArrayListUnmanaged([]const u8) = .{},
    owned_arg_values: std.ArrayListUnmanaged([]u8) = .{},

    fn deinit(self: *MachineRunArgs, allocator: std.mem.Allocator) void {
        self.args.deinit(allocator);
        for (self.owned_arg_values.items) |value| allocator.free(value);
        self.owned_arg_values.deinit(allocator);
        self.* = .{};
    }
};

fn buildMachineRunArgs(
    allocator: std.mem.Allocator,
    fly_config: model.FlyTargetConfig,
    target_name: []const u8,
    instance_name: []const u8,
    machine_name: []const u8,
    authorized_key: ?[]const u8,
) !MachineRunArgs {
    var run_args = MachineRunArgs{};
    errdefer run_args.deinit(allocator);

    try run_args.args.appendSlice(allocator, &.{
        "flyctl",
        "machine",
        "run",
        fly_config.image,
        "--app",
        fly_config.app,
        "--detach",
        "--name",
        machine_name,
        "--vm-size",
        fly_config.vm_size,
    });

    try appendMetadataArg(allocator, &run_args, "rove_managed", "true");
    try appendMetadataArg(allocator, &run_args, "rove_target", target_name);
    try appendMetadataArg(allocator, &run_args, "rove_instance", instance_name);

    try appendPortArgs(allocator, &run_args.args, &run_args.owned_arg_values, fly_config);
    try appendConfiguredEnv(allocator, &run_args.args, &run_args.owned_arg_values, fly_config, instance_name, machine_name);

    if (fly_config.inject_authorized_keys) {
        const public_key = authorized_key orelse return error.MissingAuthorizedKey;
        try run_args.args.append(allocator, "--env");
        const authorized_keys_env = try std.fmt.allocPrint(allocator, "ROVE_AUTHORIZED_KEYS={s}", .{public_key});
        try run_args.owned_arg_values.append(allocator, authorized_keys_env);
        try run_args.args.append(allocator, authorized_keys_env);
    }

    if (selectedRegion(fly_config)) |region| {
        try run_args.args.appendSlice(allocator, &.{ "--region", region });
    }

    return run_args;
}

fn appendMetadataArg(
    allocator: std.mem.Allocator,
    run_args: *MachineRunArgs,
    key: []const u8,
    value: []const u8,
) !void {
    try run_args.args.append(allocator, "--metadata");
    const rendered = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
    try run_args.owned_arg_values.append(allocator, rendered);
    try run_args.args.append(allocator, rendered);
}

fn generatedMachineName(
    allocator: std.mem.Allocator,
    instance_name: []const u8,
) ![]u8 {
    const slug = try machineNameSlug(allocator, instance_name);
    defer allocator.free(slug);

    const suffix = std.crypto.random.int(u32);
    return std.fmt.allocPrint(allocator, "rove-{s}-{x}", .{ slug, suffix });
}

fn machineNameSlug(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    var previous_dash = false;
    for (raw) |char| {
        switch (char) {
            'a'...'z', '0'...'9' => {
                try out.append(allocator, char);
                previous_dash = false;
            },
            'A'...'Z' => {
                try out.append(allocator, std.ascii.toLower(char));
                previous_dash = false;
            },
            '-', '_', '.', ' ' => {
                if (previous_dash or out.items.len == 0) continue;
                try out.append(allocator, '-');
                previous_dash = true;
            },
            else => {
                if (previous_dash or out.items.len == 0) continue;
                try out.append(allocator, '-');
                previous_dash = true;
            },
        }
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "machine");
    }

    return out.toOwnedSlice(allocator);
}

fn appendPortArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayListUnmanaged([]const u8),
    owned_arg_values: *std.ArrayListUnmanaged([]u8),
    fly_config: model.FlyTargetConfig,
) !void {
    if (fly_config.ports) |ports| {
        for (ports) |port| {
            try args.append(allocator, "--port");
            const rendered = try std.fmt.allocPrint(allocator, "{d}:{d}/{s}", .{
                port.external,
                port.internal,
                port.protocol,
            });
            try owned_arg_values.append(allocator, rendered);
            try args.append(allocator, rendered);
        }
        return;
    }

    try args.appendSlice(allocator, &.{ "--port", "22:2222/tcp" });
}

fn appendConfiguredEnv(
    allocator: std.mem.Allocator,
    args: *std.ArrayListUnmanaged([]const u8),
    owned_arg_values: *std.ArrayListUnmanaged([]u8),
    fly_config: model.FlyTargetConfig,
    instance_name: []const u8,
    machine_name: []const u8,
) !void {
    const env = fly_config.env orelse return;
    var iterator = env.object.iterator();
    while (iterator.next()) |entry| {
        const rendered_value = try renderEnvValue(
            allocator,
            entry.value_ptr.*,
            fly_config.app,
            instance_name,
            machine_name,
        );
        defer allocator.free(rendered_value);

        try args.append(allocator, "--env");
        const rendered_env = try std.fmt.allocPrint(allocator, "{s}={s}", .{
            entry.key_ptr.*,
            rendered_value,
        });
        try owned_arg_values.append(allocator, rendered_env);
        try args.append(allocator, rendered_env);
    }
}

fn renderEnvValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    app: []const u8,
    instance_name: []const u8,
    machine_name: []const u8,
) ![]u8 {
    return switch (value) {
        .string => |string| try renderTemplate(allocator, string, app, instance_name, machine_name),
        .integer => |integer| try std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .float => |float| try std.fmt.allocPrint(allocator, "{d}", .{float}),
        .number_string => |number_string| allocator.dupe(u8, number_string),
        .bool => |boolean| allocator.dupe(u8, if (boolean) "true" else "false"),
        else => error.InvalidFlyEnv,
    };
}

fn renderSshHost(
    allocator: std.mem.Allocator,
    fly_config: model.FlyTargetConfig,
    instance_name: ?[]const u8,
    machine_name: ?[]const u8,
) ![]u8 {
    const template = fly_config.ssh_host orelse {
        return std.fmt.allocPrint(allocator, "{s}.fly.dev", .{fly_config.app});
    };

    return renderTemplate(
        allocator,
        template,
        fly_config.app,
        instance_name orelse "",
        machine_name orelse "",
    );
}

fn sshPortForConfig(fly_config: model.FlyTargetConfig) u16 {
    if (fly_config.ssh_port) |ssh_port| return ssh_port;

    if (fly_config.ports) |ports| {
        for (ports) |port| {
            if (port.internal == 2222 and std.ascii.eqlIgnoreCase(port.protocol, "tcp")) {
                return port.external;
            }
        }
    }

    return 22;
}

fn renderTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    app: []const u8,
    instance_name: []const u8,
    machine_name: []const u8,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    var index: usize = 0;
    while (index < template.len) {
        if (std.mem.startsWith(u8, template[index..], "{name}")) {
            try out.appendSlice(allocator, instance_name);
            index += "{name}".len;
        } else if (std.mem.startsWith(u8, template[index..], "{machine_name}")) {
            try out.appendSlice(allocator, machine_name);
            index += "{machine_name}".len;
        } else if (std.mem.startsWith(u8, template[index..], "{app}")) {
            try out.appendSlice(allocator, app);
            index += "{app}".len;
        } else {
            try out.append(allocator, template[index]);
            index += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn selectedRegion(target: model.FlyTargetConfig) ?[]const u8 {
    if (target.region) |region| return region;
    if (target.region_preference) |preference| {
        if (preference.len > 0) return preference[0];
    }

    return null;
}

fn lookupMachineByName(
    allocator: std.mem.Allocator,
    app: []const u8,
    machine_name: []const u8,
) !FoundMachine {
    var attempt: usize = 0;
    while (attempt < 10) : (attempt += 1) {
        const result = try exec.run(allocator, &.{
            "flyctl",
            "machine",
            "list",
            "--app",
            app,
            "--json",
        });
        defer result.deinit(allocator);

        if (!result.succeeded()) {
            std.debug.print("[error] flyctl machine list failed\n{s}", .{result.stderr});
            return error.CommandFailed;
        }

        if (try findListedMachine(allocator, result.stdout, .name, machine_name)) |machine| {
            return machine;
        }

        std.Thread.sleep(250 * std.time.ns_per_ms);
    }

    return error.CreatedMachineNotFound;
}

fn lookupMachineById(
    allocator: std.mem.Allocator,
    app: []const u8,
    machine_id: []const u8,
) !FoundMachine {
    const result = try exec.run(allocator, &.{
        "flyctl",
        "machine",
        "list",
        "--app",
        app,
        "--json",
    });
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        std.debug.print("[error] flyctl machine list failed\n{s}", .{result.stderr});
        return error.CommandFailed;
    }

    return (try findListedMachine(allocator, result.stdout, .id, machine_id)) orelse .{
        .exists = false,
    };
}

const MatchField = enum {
    id,
    name,
};

fn findListedMachine(
    allocator: std.mem.Allocator,
    json_slice: []const u8,
    field: MatchField,
    needle: []const u8,
) !?FoundMachine {
    var parsed = try std.json.parseFromSlice([]const ListedMachine, allocator, json_slice, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    for (parsed.value) |machine| {
        const matched = switch (field) {
            .id => std.mem.eql(u8, machine.id, needle),
            .name => std.mem.eql(u8, machine.name, needle),
        };
        if (!matched) continue;

        return .{
            .exists = true,
            .id = try allocator.dupe(u8, machine.id),
            .name = try allocator.dupe(u8, machine.name),
            .state = if (machine.state) |state| try allocator.dupe(u8, state) else null,
            .region = if (machine.region) |region| try allocator.dupe(u8, region) else null,
        };
    }

    return null;
}

test "select fixed region first" {
    const target = model.TargetConfig{
        .name = "cpu",
        .provider = .fly,
        .app = "devbox",
        .image = "registry.fly.io/devbox:latest",
        .vm_size = "shared-cpu-2x",
        .region = "ord",
        .region_preference = &.{ "iad", "dfw" },
        .ssh_user = "rove",
        .startup_script = "./scripts/bootstrap.sh",
    };

    try std.testing.expectEqualStrings("ord", selectedRegion(target).?);
}

test "select first preferred region when fixed region is absent" {
    const target = model.TargetConfig{
        .name = "cpu",
        .provider = .fly,
        .app = "devbox",
        .image = "registry.fly.io/devbox:latest",
        .vm_size = "shared-cpu-2x",
        .region_preference = &.{ "iad", "dfw" },
        .ssh_user = "rove",
        .startup_script = "./scripts/bootstrap.sh",
    };

    try std.testing.expectEqualStrings("iad", selectedRegion(target).?);
}

test "render fly launch templates" {
    const allocator = std.testing.allocator;
    const rendered = try renderTemplate(allocator, "mesh-{name}-{machine_name}-{app}", "devbox", "work", "rove-work-1234");
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("mesh-work-rove-work-1234-devbox", rendered);
}

test "default fly machine run args preserve public ssh launch path" {
    const allocator = std.testing.allocator;
    var run_args = try buildMachineRunArgs(
        allocator,
        .{
            .app = "devbox",
            .image = "registry.fly.io/devbox:latest",
            .vm_size = "shared-cpu-2x",
        },
        "devbox",
        "work",
        "rove-work-1234",
        "ssh-ed25519 AAAATEST rove-test",
    );
    defer run_args.deinit(allocator);

    const expected = [_][]const u8{
        "flyctl",
        "machine",
        "run",
        "registry.fly.io/devbox:latest",
        "--app",
        "devbox",
        "--detach",
        "--name",
        "rove-work-1234",
        "--vm-size",
        "shared-cpu-2x",
        "--metadata",
        "rove_managed=true",
        "--metadata",
        "rove_target=devbox",
        "--metadata",
        "rove_instance=work",
        "--port",
        "22:2222/tcp",
        "--env",
        "ROVE_AUTHORIZED_KEYS=ssh-ed25519 AAAATEST rove-test",
    };
    try expectArgsEqual(expected[0..], run_args.args.items);
}

test "private fly machine run args omit public ssh and render env" {
    const allocator = std.testing.allocator;
    var parsed_env = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "TAILSCALE_HOSTNAME": "mesh-{name}",
        \\  "TAILSCALE_SERVE_SSH": "1"
        \\}
    , .{ .allocate = .alloc_always });
    defer parsed_env.deinit();

    const fly_config = model.FlyTargetConfig{
        .app = "devbox",
        .image = "registry.fly.io/devbox:latest",
        .vm_size = "shared-cpu-2x",
        .ports = &.{},
        .env = parsed_env.value,
        .inject_authorized_keys = false,
        .ssh_host = "mesh-{name}",
        .ssh_port = 2222,
    };

    var run_args = try buildMachineRunArgs(
        allocator,
        fly_config,
        "devbox",
        "work",
        "rove-work-1234",
        null,
    );
    defer run_args.deinit(allocator);

    const expected = [_][]const u8{
        "flyctl",
        "machine",
        "run",
        "registry.fly.io/devbox:latest",
        "--app",
        "devbox",
        "--detach",
        "--name",
        "rove-work-1234",
        "--vm-size",
        "shared-cpu-2x",
        "--metadata",
        "rove_managed=true",
        "--metadata",
        "rove_target=devbox",
        "--metadata",
        "rove_instance=work",
        "--env",
        "TAILSCALE_HOSTNAME=mesh-work",
        "--env",
        "TAILSCALE_SERVE_SSH=1",
    };
    try expectArgsEqual(expected[0..], run_args.args.items);
    try expectArgAbsent(run_args.args.items, "--port");
    try expectArgPrefixAbsent(run_args.args.items, "ROVE_AUTHORIZED_KEYS=");

    const host = try renderSshHost(allocator, fly_config, "work", "rove-work-1234");
    defer allocator.free(host);
    try std.testing.expectEqualStrings("mesh-work", host);
    try std.testing.expectEqual(@as(u16, 2222), sshPortForConfig(fly_config));
}

test "empty configured ports emit no fly public port args" {
    const allocator = std.testing.allocator;
    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);
    var owned = std.ArrayListUnmanaged([]u8){};
    defer {
        for (owned.items) |value| allocator.free(value);
        owned.deinit(allocator);
    }

    try appendPortArgs(allocator, &args, &owned, .{
        .app = "devbox",
        .image = "registry.fly.io/devbox:latest",
        .vm_size = "shared-cpu-2x",
        .ports = &.{},
    });

    try std.testing.expectEqual(@as(usize, 0), args.items.len);
}

test "default fly ports preserve public ssh mapping" {
    const allocator = std.testing.allocator;
    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);
    var owned = std.ArrayListUnmanaged([]u8){};
    defer {
        for (owned.items) |value| allocator.free(value);
        owned.deinit(allocator);
    }

    try appendPortArgs(allocator, &args, &owned, .{
        .app = "devbox",
        .image = "registry.fly.io/devbox:latest",
        .vm_size = "shared-cpu-2x",
    });

    try std.testing.expectEqual(@as(usize, 2), args.items.len);
    try std.testing.expectEqualStrings("--port", args.items[0]);
    try std.testing.expectEqualStrings("22:2222/tcp", args.items[1]);
}

test "private ssh host and port come from config" {
    const allocator = std.testing.allocator;
    const fly_config = model.FlyTargetConfig{
        .app = "devbox",
        .image = "registry.fly.io/devbox:latest",
        .vm_size = "shared-cpu-2x",
        .ports = &.{},
        .ssh_host = "mesh-{name}",
        .ssh_port = 2222,
    };
    const host = try renderSshHost(allocator, fly_config, "work", "rove-work-1234");
    defer allocator.free(host);

    try std.testing.expectEqualStrings("mesh-work", host);
    try std.testing.expectEqual(@as(u16, 2222), sshPortForConfig(fly_config));
}

test "machine name slug normalizes instance names" {
    const allocator = std.testing.allocator;
    const slug = try machineNameSlug(allocator, "Devbox Sam.Work");
    defer allocator.free(slug);

    try std.testing.expectEqualStrings("devbox-sam-work", slug);
}

test "listed machine parsing ignores extra fly fields" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {
        \\    "id": "123",
        \\    "name": "rove-smoke",
        \\    "state": "started",
        \\    "region": "iad",
        \\    "private_ip": "fdaa::1",
        \\    "config": {
        \\      "image": "registry.fly.io/example:latest"
        \\    }
        \\  }
        \\]
    ;

    const found = try findListedMachine(allocator, json, .name, "rove-smoke");
    defer if (found) |machine| machine.deinit(allocator);

    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("123", found.?.id.?);
    try std.testing.expectEqualStrings("iad", found.?.region.?);
}

fn expectArgsEqual(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

fn expectArgAbsent(args: []const []const u8, needle: []const u8) !void {
    for (args) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, needle));
    }
}

fn expectArgPrefixAbsent(args: []const []const u8, prefix: []const u8) !void {
    for (args) |arg| {
        try std.testing.expect(!std.mem.startsWith(u8, arg, prefix));
    }
}
