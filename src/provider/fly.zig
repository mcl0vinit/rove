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

    const managed_key = try keys.ensureManagedKeyPair(allocator);
    defer managed_key.deinit(allocator);

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &.{
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

    if (fly_config.vm_memory) |memory| {
        try args.appendSlice(allocator, &.{ "--vm-memory", memory });
    }

    try args.appendSlice(allocator, &.{
        "--port",
        "22:2222/tcp",
        "--metadata",
    });

    const managed_metadata = try std.fmt.allocPrint(allocator, "rove_managed=true", .{});
    defer allocator.free(managed_metadata);
    try args.append(allocator, managed_metadata);

    try args.append(allocator, "--metadata");
    const target_metadata = try std.fmt.allocPrint(allocator, "rove_target={s}", .{request.target_name});
    defer allocator.free(target_metadata);
    try args.append(allocator, target_metadata);

    try args.append(allocator, "--metadata");
    const instance_metadata = try std.fmt.allocPrint(allocator, "rove_instance={s}", .{request.instance_name});
    defer allocator.free(instance_metadata);
    try args.append(allocator, instance_metadata);

    try args.append(allocator, "--env");
    const authorized_keys_env = try std.fmt.allocPrint(allocator, "ROVE_AUTHORIZED_KEYS={s}", .{managed_key.public_key});
    defer allocator.free(authorized_keys_env);
    try args.append(allocator, authorized_keys_env);

    if (selectedRegion(fly_config)) |region| {
        try args.appendSlice(allocator, &.{ "--region", region });
    }

    const run_result = try exec.run(allocator, args.items);
    defer run_result.deinit(allocator);

    if (!run_result.succeeded()) {
        std.debug.print("[error] flyctl machine run failed\n{s}", .{run_result.stderr});
        return error.CommandFailed;
    }

    const machine = try lookupMachineByName(allocator, fly_config.app, machine_name);
    defer machine.deinit(allocator);

    return .{
        .machine_id = try allocator.dupe(u8, machine.id.?),
        .host = try std.fmt.allocPrint(allocator, "{s}.fly.dev", .{fly_config.app}),
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
        .host = try std.fmt.allocPrint(allocator, "{s}.fly.dev", .{fly_config.app}),
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
