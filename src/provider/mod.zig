const std = @import("std");
const config = @import("../config.zig");
const model = @import("../model.zig");
const fly = @import("fly.zig");
const vast = @import("vast.zig");

pub const ProviderTargetConfig = union(model.ProviderKind) {
    fly: model.FlyTargetConfig,
    vast: model.VastTargetConfig,
};

pub const CreateRequest = struct {
    target_name: []const u8,
    provider_config: ProviderTargetConfig,
    instance_name: []const u8,
    verbose: bool = false,
};

pub const CreateResult = struct {
    machine_id: []const u8,
    machine_name: ?[]const u8 = null,
    host: []const u8,
    ssh_port: u16 = 22,
    region: ?[]const u8 = null,

    pub fn deinit(self: CreateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.machine_id);
        allocator.free(self.host);
        if (self.machine_name) |machine_name| allocator.free(machine_name);
        if (self.region) |region| allocator.free(region);
    }
};

pub const DestroyRequest = struct {
    provider_config: ProviderTargetConfig,
    machine_id: []const u8,
    verbose: bool = false,
};

pub const InspectRequest = struct {
    provider_config: ProviderTargetConfig,
    machine_id: []const u8,
};

pub const InspectResult = struct {
    exists: bool,
    machine_name: ?[]const u8 = null,
    host: ?[]const u8 = null,
    ssh_port: ?u16 = null,
    region: ?[]const u8 = null,
    remote_state: ?[]const u8 = null,

    pub fn deinit(self: InspectResult, allocator: std.mem.Allocator) void {
        if (self.machine_name) |machine_name| allocator.free(machine_name);
        if (self.host) |host| allocator.free(host);
        if (self.region) |region| allocator.free(region);
        if (self.remote_state) |remote_state| allocator.free(remote_state);
    }
};

pub const DoctorCheck = struct {
    name: []const u8,
    argv: []const []const u8,
    ok_detail: []const u8,
};

pub const TargetSummary = struct {
    scope_label: []const u8 = "scope",
    scope: ?[]const u8 = null,
    image: ?[]const u8 = null,
    size_label: []const u8 = "machine",
    size: ?[]const u8 = null,
};

const fly_version_args = [_][]const u8{ "flyctl", "version" };
const fly_auth_args = [_][]const u8{ "flyctl", "auth", "whoami" };
const vast_help_args = [_][]const u8{ "vastai", "--help" };
const vast_auth_args = [_][]const u8{ "vastai", "show", "user" };
const fly_doctor_checks = [_]DoctorCheck{
    .{
        .name = "flyctl",
        .argv = &fly_version_args,
        .ok_detail = "flyctl is available",
    },
    .{
        .name = "fly auth",
        .argv = &fly_auth_args,
        .ok_detail = "Fly auth is configured",
    },
};
const vast_doctor_checks = [_]DoctorCheck{
    .{
        .name = "vastai",
        .argv = &vast_help_args,
        .ok_detail = "vastai is available",
    },
    .{
        .name = "vast auth",
        .argv = &vast_auth_args,
        .ok_detail = "Vast.ai auth is configured",
    },
};

pub fn create(
    allocator: std.mem.Allocator,
    provider: model.ProviderKind,
    request: CreateRequest,
) !CreateResult {
    return switch (provider) {
        .fly => fly.create(allocator, request),
        .vast => vast.create(allocator, request),
    };
}

pub fn doctorChecks(provider: model.ProviderKind) []const DoctorCheck {
    return switch (provider) {
        .fly => &fly_doctor_checks,
        .vast => &vast_doctor_checks,
    };
}

pub fn targetSummary(target: model.TargetConfig) TargetSummary {
    return switch (target.provider) {
        .fly => blk: {
            const fly_config = config.resolveFlyTarget(target);
            break :blk .{
                .scope_label = "app",
                .scope = fly_config.app,
                .image = fly_config.image,
                .size_label = "vm_size",
                .size = fly_config.vm_size,
            };
        },
        .vast => blk: {
            const vast_config = config.resolveVastTarget(target);
            break :blk .{
                .scope_label = if (vast_config.offer_id == null) "query" else "offer",
                .scope = if (vast_config.offer_id == null) vast_config.query else "fixed",
                .image = vast_config.image,
                .size_label = "selection",
                .size = if (vast_config.offer_id == null) "marketplace" else "fixed offer",
            };
        },
    };
}

pub fn scopeForConfig(provider_config: ProviderTargetConfig) ?[]const u8 {
    return switch (provider_config) {
        .fly => |fly_config| fly_config.app,
        .vast => null,
    };
}

pub fn legacyAppAliasForConfig(provider_config: ProviderTargetConfig) ?[]const u8 {
    return switch (provider_config) {
        .fly => |fly_config| fly_config.app,
        .vast => null,
    };
}

pub fn fallbackHost(
    allocator: std.mem.Allocator,
    provider_config: ProviderTargetConfig,
) !?[]u8 {
    return switch (provider_config) {
        .fly => |fly_config| try std.fmt.allocPrint(allocator, "{s}.fly.dev", .{fly_config.app}),
        .vast => null,
    };
}

pub fn renderPlacementSummary(
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
        .vast => {
            const vast_config = config.resolveVastTarget(target);
            if (vast_config.offer_id) |_| return allocator.dupe(u8, "fixed offer");
            return allocator.dupe(u8, "marketplace search");
        },
    }

    return allocator.dupe(u8, "provider-selected placement");
}

pub fn destroy(
    allocator: std.mem.Allocator,
    provider: model.ProviderKind,
    request: DestroyRequest,
) !void {
    switch (provider) {
        .fly => try fly.destroy(allocator, request),
        .vast => try vast.destroy(allocator, request),
    }
}

pub fn inspect(
    allocator: std.mem.Allocator,
    provider: model.ProviderKind,
    request: InspectRequest,
) !InspectResult {
    return switch (provider) {
        .fly => fly.inspect(allocator, request),
        .vast => vast.inspect(allocator, request),
    };
}
