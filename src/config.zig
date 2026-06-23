const std = @import("std");
const model = @import("model.zig");
const paths = @import("paths.zig");

pub const Error = std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.Dir.AccessError ||
    std.json.ParseError(std.json.Scanner) ||
    error{
        DuplicateTarget,
        EmptyTargetName,
        MissingApp,
        MissingImage,
        MissingVastQuery,
        MissingVmSize,
        MissingSshUser,
        MissingRegionPreference,
        InvalidFlyEnv,
        InvalidFlyPort,
        InvalidSshPort,
        TargetNotFound,
    };

const ValidationOptions = struct {
    check_startup_script_paths: bool = true,
};

pub fn load(
    allocator: std.mem.Allocator,
    path_override: ?[]const u8,
) Error!std.json.Parsed(model.ConfigFile) {
    const path = path_override orelse paths.defaultConfigPath();
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(contents);

    return parseSlice(allocator, contents, .{ .check_startup_script_paths = true });
}

pub fn parseSlice(
    allocator: std.mem.Allocator,
    contents: []const u8,
    validation_options: ValidationOptions,
) Error!std.json.Parsed(model.ConfigFile) {
    var parsed = try std.json.parseFromSlice(model.ConfigFile, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();

    try validate(parsed.value.targets, validation_options);

    return parsed;
}

pub fn resolveTarget(
    file: *const model.ConfigFile,
    name: []const u8,
) Error!*const model.TargetConfig {
    for (file.targets) |*target| {
        if (std.mem.eql(u8, target.name, name)) {
            return target;
        }
    }

    return error.TargetNotFound;
}

pub fn resolveFlyTarget(target: model.TargetConfig) model.FlyTargetConfig {
    if (target.fly) |fly| {
        return .{
            .app = if (fly.app.len > 0) fly.app else target.app,
            .image = if (fly.image.len > 0) fly.image else target.image,
            .vm_size = if (fly.vm_size.len > 0) fly.vm_size else target.vm_size,
            .region = fly.region orelse target.region,
            .region_preference = fly.region_preference orelse target.region_preference,
            .ports = fly.ports,
            .env = fly.env,
            .inject_authorized_keys = fly.inject_authorized_keys,
            .ssh_host = fly.ssh_host,
            .ssh_port = fly.ssh_port,
        };
    }

    return .{
        .app = target.app,
        .image = target.image,
        .vm_size = target.vm_size,
        .region = target.region,
        .region_preference = target.region_preference,
    };
}

pub fn resolveVastTarget(target: model.TargetConfig) model.VastTargetConfig {
    return target.vast orelse .{};
}

fn validate(
    targets: []const model.TargetConfig,
    options: ValidationOptions,
) Error!void {
    for (targets, 0..) |target, index| {
        if (target.name.len == 0) return error.EmptyTargetName;
        if (target.ssh_user.len == 0) return error.MissingSshUser;

        switch (target.provider) {
            .fly => {
                const fly = resolveFlyTarget(target);
                if (fly.app.len == 0) return error.MissingApp;
                if (fly.image.len == 0) return error.MissingImage;
                if (fly.vm_size.len == 0) return error.MissingVmSize;
                if (fly.region_preference) |preference| {
                    if (preference.len == 0) return error.MissingRegionPreference;
                }
                if (fly.ports) |ports| {
                    for (ports) |port| {
                        if (port.external == 0 or port.internal == 0 or port.protocol.len == 0) {
                            return error.InvalidFlyPort;
                        }
                    }
                }
                if (fly.env) |env| {
                    if (env != .object) return error.InvalidFlyEnv;
                    var iterator = env.object.iterator();
                    while (iterator.next()) |entry| {
                        if (entry.key_ptr.*.len == 0) return error.InvalidFlyEnv;
                        switch (entry.value_ptr.*) {
                            .string, .integer, .float, .number_string, .bool => {},
                            else => return error.InvalidFlyEnv,
                        }
                    }
                }
                if (fly.ssh_port) |ssh_port| {
                    if (ssh_port == 0) return error.InvalidSshPort;
                }
            },
            .vast => {
                const vast = resolveVastTarget(target);
                if (vast.offer_id == null and vast.query.len == 0) return error.MissingVastQuery;
                if (vast.image.len == 0 and vast.template_hash == null) return error.MissingImage;
            },
        }

        if (options.check_startup_script_paths) {
            if (target.startup_script) |startup_script| {
                try std.fs.cwd().access(startup_script, .{});
            }
        }

        for (targets[index + 1 ..]) |other| {
            if (std.mem.eql(u8, target.name, other.name)) {
                return error.DuplicateTarget;
            }
        }
    }
}

test "parse and resolve target with provider scoped fly config" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "ssh_user": "rove",
        \\      "startup_script": "./scripts/bootstrap.sh",
        \\      "fly": {
        \\        "app": "devbox",
        \\        "image": "registry.fly.io/devbox:latest",
        \\        "vm_size": "shared-cpu-2x"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseSlice(allocator, contents, ValidationOptions{
        .check_startup_script_paths = false,
    });
    defer parsed.deinit();

    const target = try resolveTarget(&parsed.value, "devbox");
    try std.testing.expectEqual(model.ProviderKind.fly, target.provider);

    const fly = resolveFlyTarget(target.*);
    try std.testing.expectEqualStrings("devbox", fly.app);
    try std.testing.expectEqualStrings("registry.fly.io/devbox:latest", fly.image);
    try std.testing.expectEqualStrings("shared-cpu-2x", fly.vm_size);
}

test "parse fly private access launch options" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "ssh_user": "rove",
        \\      "ssh_identity_file": "~/.ssh/id_ed25519",
        \\      "fly": {
        \\        "app": "devbox",
        \\        "image": "registry.fly.io/devbox:latest",
        \\        "vm_size": "shared-cpu-2x",
        \\        "ports": [],
        \\        "inject_authorized_keys": false,
        \\        "ssh_host": "mesh-{name}",
        \\        "ssh_port": 2222,
        \\        "env": {
        \\          "TAILSCALE_HOSTNAME": "mesh-{name}",
        \\          "TAILSCALE_SERVE_SSH": "1"
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseSlice(allocator, contents, ValidationOptions{
        .check_startup_script_paths = false,
    });
    defer parsed.deinit();

    const target = try resolveTarget(&parsed.value, "devbox");
    try std.testing.expectEqualStrings("~/.ssh/id_ed25519", target.ssh_identity_file.?);

    const fly = resolveFlyTarget(target.*);
    try std.testing.expect(fly.ports != null);
    try std.testing.expectEqual(@as(usize, 0), fly.ports.?.len);
    try std.testing.expect(!fly.inject_authorized_keys);
    try std.testing.expectEqualStrings("mesh-{name}", fly.ssh_host.?);
    try std.testing.expectEqual(@as(u16, 2222), fly.ssh_port.?);
    try std.testing.expect(fly.env != null);
    try std.testing.expect(fly.env.? == .object);
}

test "parse legacy top-level fly config" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "app": "devbox",
        \\      "image": "registry.fly.io/devbox:latest",
        \\      "vm_size": "shared-cpu-2x",
        \\      "ssh_user": "rove"
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseSlice(allocator, contents, ValidationOptions{
        .check_startup_script_paths = false,
    });
    defer parsed.deinit();

    const target = try resolveTarget(&parsed.value, "devbox");
    const fly = resolveFlyTarget(target.*);
    try std.testing.expectEqualStrings("devbox", fly.app);
}

test "parse and resolve vast target config" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "gpu",
        \\      "provider": "vast",
        \\      "ssh_user": "root",
        \\      "vast": {
        \\        "query": "gpu_name=RTX_4090 num_gpus=1 verified=true direct_port_count>=1 rentable=true",
        \\        "image": "pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime",
        \\        "disk_gb": 80,
        \\        "order": "dlperf_usd-"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseSlice(allocator, contents, ValidationOptions{
        .check_startup_script_paths = false,
    });
    defer parsed.deinit();

    const target = try resolveTarget(&parsed.value, "gpu");
    try std.testing.expectEqual(model.ProviderKind.vast, target.provider);

    const vast = resolveVastTarget(target.*);
    try std.testing.expectEqualStrings("pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime", vast.image);
    try std.testing.expectEqual(@as(u32, 80), vast.disk_gb);
}

test "reject duplicate target names" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "ssh_user": "rove",
        \\      "startup_script": "./scripts/bootstrap.sh",
        \\      "fly": {
        \\        "app": "devbox",
        \\        "image": "registry.fly.io/devbox:latest",
        \\        "vm_size": "shared-cpu-2x"
        \\      }
        \\    },
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "ssh_user": "rove",
        \\      "startup_script": "./scripts/bootstrap.sh",
        \\      "fly": {
        \\        "app": "devbox",
        \\        "image": "registry.fly.io/devbox:latest",
        \\        "vm_size": "shared-cpu-2x"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    try std.testing.expectError(
        error.DuplicateTarget,
        parseSlice(allocator, contents, ValidationOptions{
            .check_startup_script_paths = false,
        }),
    );
}

test "parse target without startup script" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "ssh_user": "rove",
        \\      "fly": {
        \\        "app": "devbox",
        \\        "image": "registry.fly.io/devbox:latest",
        \\        "vm_size": "shared-cpu-2x"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseSlice(allocator, contents, ValidationOptions{
        .check_startup_script_paths = false,
    });
    defer parsed.deinit();

    const target = try resolveTarget(&parsed.value, "devbox");
    try std.testing.expect(target.startup_script == null);
}
