const std = @import("std");
const exec = @import("../exec.zig");
const keys = @import("../keys.zig");
const model = @import("../model.zig");
const provider = @import("mod.zig");

const endpoint_timeout_ms = 180 * std.time.ms_per_s;
const endpoint_poll_interval_ms = 2 * std.time.ms_per_s;

pub fn create(
    allocator: std.mem.Allocator,
    request: provider.CreateRequest,
) !provider.CreateResult {
    const vast_config = request.provider_config.vast;
    const offer_id = try selectedOfferId(allocator, vast_config);

    const managed_key = try keys.ensureManagedKeyPair(allocator);
    defer managed_key.deinit(allocator);

    const offer_id_arg = try std.fmt.allocPrint(allocator, "{d}", .{offer_id});
    defer allocator.free(offer_id_arg);

    const disk_arg = try std.fmt.allocPrint(allocator, "{d}", .{vast_config.disk_gb});
    defer allocator.free(disk_arg);

    const label = try generatedInstanceLabel(allocator, request.instance_name);
    defer allocator.free(label);

    var bid_arg: ?[]u8 = null;
    defer if (bid_arg) |value| allocator.free(value);
    if (vast_config.bid_price) |bid_price| {
        bid_arg = try std.fmt.allocPrint(allocator, "{d}", .{bid_price});
    }

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &.{
        "vastai",
        "create",
        "instance",
        offer_id_arg,
    });

    if (vast_config.image.len > 0) {
        try args.appendSlice(allocator, &.{ "--image", vast_config.image });
    }
    if (vast_config.template_hash) |template_hash| {
        try args.appendSlice(allocator, &.{ "--template_hash", template_hash });
    }

    try args.appendSlice(allocator, &.{
        "--disk",
        disk_arg,
        "--ssh",
        "--label",
        label,
    });

    if (vast_config.direct) try args.append(allocator, "--direct");
    if (vast_config.cancel_unavail) try args.append(allocator, "--cancel-unavail");
    if (vast_config.env) |env| try args.appendSlice(allocator, &.{ "--env", env });
    if (vast_config.onstart_cmd) |onstart_cmd| try args.appendSlice(allocator, &.{ "--onstart-cmd", onstart_cmd });
    if (bid_arg) |bid_price| try args.appendSlice(allocator, &.{ "--bid_price", bid_price });
    try args.append(allocator, "--raw");

    const create_result = try exec.run(allocator, args.items);
    defer create_result.deinit(allocator);

    if (!create_result.succeeded()) {
        std.debug.print("[error] vastai create instance failed\n{s}", .{create_result.stderr});
        return error.CommandFailed;
    }

    const instance_id_value = try parseCreatedInstanceId(allocator, create_result.stdout);
    const instance_id = try std.fmt.allocPrint(allocator, "{d}", .{instance_id_value});
    errdefer allocator.free(instance_id);

    attachManagedSshKey(allocator, instance_id, managed_key.public_key) catch |err| {
        std.debug.print("[error] Vast instance {s} was created, but attaching the managed SSH key failed: {s}\n", .{
            instance_id,
            @errorName(err),
        });
        return err;
    };

    const inspected = waitForEndpoint(allocator, request.provider_config, instance_id) catch |err| {
        std.debug.print("[error] Vast instance {s} was created, but no SSH endpoint became available: {s}\n", .{
            instance_id,
            @errorName(err),
        });
        return err;
    };
    defer inspected.deinit(allocator);

    const host = inspected.host orelse return error.MissingSshHost;
    const ssh_port = inspected.ssh_port orelse return error.MissingSshPort;

    return .{
        .machine_id = instance_id,
        .machine_name = if (inspected.machine_name) |machine_name|
            try allocator.dupe(u8, machine_name)
        else
            try allocator.dupe(u8, label),
        .host = try allocator.dupe(u8, host),
        .ssh_port = ssh_port,
        .region = if (inspected.region) |region| try allocator.dupe(u8, region) else null,
    };
}

pub fn destroy(
    allocator: std.mem.Allocator,
    request: provider.DestroyRequest,
) !void {
    _ = request.provider_config;

    const result = try exec.run(allocator, &.{
        "vastai",
        "destroy",
        "instance",
        request.machine_id,
        "--raw",
    });
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        std.debug.print("[error] vastai destroy instance failed\n{s}", .{result.stderr});
        return error.CommandFailed;
    }
}

pub fn inspect(
    allocator: std.mem.Allocator,
    request: provider.InspectRequest,
) !provider.InspectResult {
    _ = request.provider_config;

    const result = try exec.run(allocator, &.{
        "vastai",
        "show",
        "instance",
        request.machine_id,
        "--raw",
    });
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (isMissingInstanceOutput(result.stderr) or isMissingInstanceOutput(result.stdout)) {
            return .{ .exists = false };
        }

        std.debug.print("[error] vastai show instance failed\n{s}", .{result.stderr});
        return error.CommandFailed;
    }

    return parseInspectResult(allocator, result.stdout);
}

fn selectedOfferId(
    allocator: std.mem.Allocator,
    vast_config: model.VastTargetConfig,
) !u64 {
    if (vast_config.offer_id) |offer_id| return offer_id;

    var args = std.ArrayListUnmanaged([]const u8){};
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &.{
        "vastai",
        "search",
        "offers",
        vast_config.query,
        "--raw",
        "--limit",
        "1",
        "-o",
        vast_config.order,
    });

    if (vast_config.search_type.len > 0) {
        try args.appendSlice(allocator, &.{ "-t", vast_config.search_type });
    }

    const result = try exec.run(allocator, args.items);
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        std.debug.print("[error] vastai search offers failed\n{s}", .{result.stderr});
        return error.CommandFailed;
    }

    return parseSelectedOfferId(allocator, result.stdout);
}

fn attachManagedSshKey(
    allocator: std.mem.Allocator,
    instance_id: []const u8,
    public_key: []const u8,
) !void {
    const result = try exec.run(allocator, &.{
        "vastai",
        "attach",
        "ssh",
        instance_id,
        public_key,
        "--raw",
    });
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        std.debug.print("[error] vastai attach ssh failed\n{s}", .{result.stderr});
        return error.CommandFailed;
    }
}

fn waitForEndpoint(
    allocator: std.mem.Allocator,
    provider_config: provider.ProviderTargetConfig,
    instance_id: []const u8,
) !provider.InspectResult {
    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(endpoint_timeout_ms));

    while (true) {
        var inspected = try inspect(allocator, .{
            .provider_config = provider_config,
            .machine_id = instance_id,
        });
        errdefer inspected.deinit(allocator);

        if (inspected.exists and inspected.host != null and inspected.ssh_port != null) {
            return inspected;
        }

        if (inspected.remote_state) |remote_state| {
            if (isTerminalCreateState(remote_state)) {
                inspected.deinit(allocator);
                return error.InstanceUnavailable;
            }
        }

        inspected.deinit(allocator);

        if (std.time.milliTimestamp() >= deadline_ms) {
            return error.ConnectTimedOut;
        }

        std.Thread.sleep(endpoint_poll_interval_ms * std.time.ns_per_ms);
    }
}

fn parseSelectedOfferId(
    allocator: std.mem.Allocator,
    json_slice: []const u8,
) !u64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_slice, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const offer = firstOfferValue(parsed.value) orelse return error.NoVastOffers;
    const id_value = getField(offer, "id") orelse return error.MissingOfferId;
    return valueAsU64(id_value) orelse error.MissingOfferId;
}

fn parseCreatedInstanceId(
    allocator: std.mem.Allocator,
    json_slice: []const u8,
) !u64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_slice, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    if (getField(parsed.value, "new_contract")) |new_contract| {
        if (valueAsU64(new_contract)) |id| return id;
    }
    if (getField(parsed.value, "instance_id")) |instance_id| {
        if (valueAsU64(instance_id)) |id| return id;
    }
    if (getField(parsed.value, "id")) |id_value| {
        if (valueAsU64(id_value)) |id| return id;
    }

    return error.MissingInstanceId;
}

fn parseInspectResult(
    allocator: std.mem.Allocator,
    json_slice: []const u8,
) !provider.InspectResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_slice, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const instance = instanceValue(parsed.value) orelse return .{ .exists = false };
    return inspectResultFromValue(allocator, instance);
}

fn inspectResultFromValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !provider.InspectResult {
    const label = firstStringField(value, &.{ "label", "name" });
    const host = firstStringField(value, &.{"ssh_host"});
    const region = firstStringField(value, &.{ "geolocation", "country" });
    const remote_state = firstStringField(value, &.{ "actual_status", "cur_state", "intended_status", "status" });
    const ssh_port = if (getField(value, "ssh_port")) |port_value|
        valueAsPort(port_value)
    else
        null;

    return .{
        .exists = true,
        .machine_name = if (label) |unwrapped| try allocator.dupe(u8, unwrapped) else null,
        .host = if (host) |unwrapped| try allocator.dupe(u8, unwrapped) else null,
        .ssh_port = ssh_port,
        .region = if (region) |unwrapped| try allocator.dupe(u8, unwrapped) else null,
        .remote_state = if (remote_state) |unwrapped| try allocator.dupe(u8, unwrapped) else null,
    };
}

fn firstOfferValue(value: std.json.Value) ?std.json.Value {
    if (firstArrayItem(value)) |offer| return offer;

    if (getField(value, "offers")) |offers| {
        if (firstArrayItem(offers)) |offer| return offer;
    }
    if (getField(value, "results")) |results| {
        if (firstArrayItem(results)) |offer| return offer;
    }

    return null;
}

fn instanceValue(value: std.json.Value) ?std.json.Value {
    if (getField(value, "instances")) |instances| {
        if (firstArrayItem(instances)) |instance| return instance;
        if (isObject(instances)) return instances;
    }
    if (getField(value, "instance")) |instance| {
        if (firstArrayItem(instance)) |first| return first;
        if (isObject(instance)) return instance;
    }
    if (firstArrayItem(value)) |instance| return instance;
    if (getField(value, "id") != null) return value;

    return null;
}

fn getField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn firstArrayItem(value: std.json.Value) ?std.json.Value {
    return switch (value) {
        .array => |array| if (array.items.len > 0) array.items[0] else null,
        else => null,
    };
}

fn isObject(value: std.json.Value) bool {
    return switch (value) {
        .object => true,
        else => false,
    };
}

fn firstStringField(value: std.json.Value, comptime fields: []const []const u8) ?[]const u8 {
    inline for (fields) |field| {
        if (getField(value, field)) |field_value| {
            if (valueAsString(field_value)) |string| return string;
        }
    }

    return null;
}

fn valueAsString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| if (string.len > 0) string else null,
        .number_string => |string| if (string.len > 0) string else null,
        else => null,
    };
}

fn valueAsU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |integer| if (integer >= 0) @as(u64, @intCast(integer)) else null,
        .float => |float| if (float >= 0) @as(u64, @intFromFloat(float)) else null,
        .number_string, .string => |string| std.fmt.parseUnsigned(u64, string, 10) catch null,
        else => null,
    };
}

fn valueAsPort(value: std.json.Value) ?u16 {
    const raw = valueAsU64(value) orelse return null;
    if (raw == 0 or raw > std.math.maxInt(u16)) return null;
    return @as(u16, @intCast(raw));
}

fn isMissingInstanceOutput(output: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(output, "not found") != null or
        std.ascii.indexOfIgnoreCase(output, "404") != null or
        std.ascii.indexOfIgnoreCase(output, "no instance") != null;
}

fn isTerminalCreateState(state: []const u8) bool {
    return std.ascii.eqlIgnoreCase(state, "exited") or
        std.ascii.eqlIgnoreCase(state, "offline") or
        std.ascii.eqlIgnoreCase(state, "unknown") or
        std.ascii.eqlIgnoreCase(state, "unloaded") or
        std.ascii.eqlIgnoreCase(state, "terminated") or
        std.ascii.eqlIgnoreCase(state, "destroyed") or
        std.ascii.eqlIgnoreCase(state, "failed");
}

fn generatedInstanceLabel(
    allocator: std.mem.Allocator,
    instance_name: []const u8,
) ![]u8 {
    const slug = try instanceNameSlug(allocator, instance_name);
    defer allocator.free(slug);

    return std.fmt.allocPrint(allocator, "rove-{s}", .{slug});
}

fn instanceNameSlug(
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

test "parse selected offer id from raw search results" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {
        \\    "id": 9001,
        \\    "gpu_name": "RTX 4090",
        \\    "num_gpus": 1
        \\  }
        \\]
    ;

    try std.testing.expectEqual(@as(u64, 9001), try parseSelectedOfferId(allocator, json));
}

test "parse created instance id" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "success": true,
        \\  "new_contract": 12345678
        \\}
    ;

    try std.testing.expectEqual(@as(u64, 12345678), try parseCreatedInstanceId(allocator, json));
}

test "parse show instance endpoint from api-shaped response" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "instances": {
        \\    "id": 883,
        \\    "label": "rove-train",
        \\    "actual_status": "running",
        \\    "cur_state": "running",
        \\    "ssh_host": "ssh2281.vast.ai",
        \\    "ssh_port": 10882,
        \\    "geolocation": "US",
        \\    "gpu_name": "RTX A5000",
        \\    "num_gpus": 1
        \\  }
        \\}
    ;

    const inspected = try parseInspectResult(allocator, json);
    defer inspected.deinit(allocator);

    try std.testing.expect(inspected.exists);
    try std.testing.expectEqualStrings("rove-train", inspected.machine_name.?);
    try std.testing.expectEqualStrings("ssh2281.vast.ai", inspected.host.?);
    try std.testing.expectEqual(@as(u16, 10882), inspected.ssh_port.?);
    try std.testing.expectEqualStrings("US", inspected.region.?);
    try std.testing.expectEqualStrings("running", inspected.remote_state.?);
}
