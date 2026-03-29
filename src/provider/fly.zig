const std = @import("std");
const exec = @import("../exec.zig");
const model = @import("../model.zig");
const provider = @import("mod.zig");

pub fn create(
    allocator: std.mem.Allocator,
    request: provider.CreateRequest,
) !provider.CreateResult {
    const machine_name = try generatedMachineName(allocator, request.target.name);
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
    target_name: []const u8,
) ![]u8 {
    const suffix = std.crypto.random.int(u32);
    return std.fmt.allocPrint(allocator, "rove-{s}-{x}", .{ target_name, suffix });
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
