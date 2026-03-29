const std = @import("std");
const exec = @import("../exec.zig");
const model = @import("../model.zig");
const provider = @import("mod.zig");

pub fn create(
    allocator: std.mem.Allocator,
    request: provider.CreateRequest,
) !provider.CreateResult {
    const machine_name = try generatedMachineName(allocator, request.instance_name);
    defer allocator.free(machine_name);

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &.{
        "flyctl",
        "machine",
        "run",
        request.target.image,
        "--app",
        request.target.app,
        "--detach",
        "--name",
        machine_name,
        "--vm-size",
        request.target.vm_size,
        "--port",
        "22:2222/tcp",
        "--metadata",
    });

    const managed_metadata = try std.fmt.allocPrint(allocator, "rove_managed=true", .{});
    defer allocator.free(managed_metadata);
    try args.append(allocator, managed_metadata);

    try args.append(allocator, "--metadata");
    const target_metadata = try std.fmt.allocPrint(allocator, "rove_target={s}", .{request.target.name});
    defer allocator.free(target_metadata);
    try args.append(allocator, target_metadata);

    try args.append(allocator, "--metadata");
    const instance_metadata = try std.fmt.allocPrint(allocator, "rove_instance={s}", .{request.instance_name});
    defer allocator.free(instance_metadata);
    try args.append(allocator, instance_metadata);

    if (selectedRegion(request.target.*)) |region| {
        try args.appendSlice(allocator, &.{ "--region", region });
    }

    const run_result = try exec.run(allocator, args.items);
    defer run_result.deinit(allocator);

    if (!run_result.succeeded()) {
        std.debug.print("[error] flyctl machine run failed\n{s}", .{run_result.stderr});
        return error.CommandFailed;
    }

    const machine = try lookupMachineByName(allocator, request.target.app, machine_name);

    return .{
        .machine_id = machine.id,
        .host = try std.fmt.allocPrint(allocator, "{s}.fly.dev", .{request.target.app}),
        .region = machine.region,
        .machine_name = machine.name,
    };
}

pub fn destroy(
    allocator: std.mem.Allocator,
    request: provider.DestroyRequest,
) !void {
    const result = try exec.run(allocator, &.{
        "flyctl",
        "machine",
        "destroy",
        "--app",
        request.app,
        "--force",
        request.machine_id,
    });
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        std.debug.print("[error] flyctl machine destroy failed\n{s}", .{result.stderr});
        return error.CommandFailed;
    }
}

pub fn flyctlVersion(allocator: std.mem.Allocator) !exec.Result {
    return exec.run(allocator, &.{ "flyctl", "version" });
}

const ListedMachine = struct {
    id: []const u8,
    name: []const u8,
    region: ?[]const u8 = null,
};

const FoundMachine = struct {
    id: []u8,
    name: []u8,
    region: ?[]u8 = null,
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

fn selectedRegion(target: model.TargetConfig) ?[]const u8 {
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

        var parsed = try std.json.parseFromSlice([]const ListedMachine, allocator, result.stdout, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        for (parsed.value) |machine| {
            if (std.mem.eql(u8, machine.name, machine_name)) {
                return .{
                    .id = try allocator.dupe(u8, machine.id),
                    .name = try allocator.dupe(u8, machine.name),
                    .region = if (machine.region) |region|
                        try allocator.dupe(u8, region)
                    else
                        null,
                };
            }
        }

        std.Thread.sleep(250 * std.time.ns_per_ms);
    }

    return error.CreatedMachineNotFound;
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
        .ssh_user = "root",
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
        .ssh_user = "root",
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
