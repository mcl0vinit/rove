const std = @import("std");
const model = @import("../model.zig");
const fly = @import("fly.zig");

pub const ProviderTargetConfig = union(model.ProviderKind) {
    fly: model.FlyTargetConfig,
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
    region: ?[]const u8 = null,
    remote_state: ?[]const u8 = null,

    pub fn deinit(self: InspectResult, allocator: std.mem.Allocator) void {
        if (self.machine_name) |machine_name| allocator.free(machine_name);
        if (self.host) |host| allocator.free(host);
        if (self.region) |region| allocator.free(region);
        if (self.remote_state) |remote_state| allocator.free(remote_state);
    }
};

pub fn create(
    allocator: std.mem.Allocator,
    provider: model.ProviderKind,
    request: CreateRequest,
) !CreateResult {
    return switch (provider) {
        .fly => fly.create(allocator, request),
    };
}

pub fn destroy(
    allocator: std.mem.Allocator,
    provider: model.ProviderKind,
    request: DestroyRequest,
) !void {
    switch (provider) {
        .fly => try fly.destroy(allocator, request),
    }
}

pub fn inspect(
    allocator: std.mem.Allocator,
    provider: model.ProviderKind,
    request: InspectRequest,
) !InspectResult {
    return switch (provider) {
        .fly => fly.inspect(allocator, request),
    };
}
