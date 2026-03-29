const std = @import("std");
const model = @import("../model.zig");
const fly = @import("fly.zig");

pub const CreateRequest = struct {
    target: *const model.TargetConfig,
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
    app: []const u8,
    machine_id: []const u8,
    verbose: bool = false,
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
