const std = @import("std");

pub const ProviderKind = enum {
    fly,
    vast,
};

pub const FlyPortConfig = struct {
    external: u16,
    internal: u16,
    protocol: []const u8 = "tcp",
};

pub const LifecycleStatus = enum {
    creating,
    provisioned,
    waiting_for_ssh,
    bootstrapping,
    ready,
    bootstrap_failed,
    provisioned_unreachable,
    destroying,
};

pub const FlyTargetConfig = struct {
    app: []const u8 = "",
    image: []const u8 = "",
    vm_size: []const u8 = "",
    vm_memory: ?[]const u8 = null,
    region: ?[]const u8 = null,
    region_preference: ?[]const []const u8 = null,
    ports: ?[]const FlyPortConfig = null,
    allow_public_ports: bool = false,
    env: ?std.json.Value = null,
    inject_authorized_keys: bool = true,
    ssh_host: ?[]const u8 = null,
    ssh_port: ?u16 = null,
};

pub const VastTargetConfig = struct {
    query: []const u8 = "",
    offer_id: ?u64 = null,
    image: []const u8 = "",
    template_hash: ?[]const u8 = null,
    disk_gb: u32 = 40,
    order: []const u8 = "dlperf_usd-",
    search_type: []const u8 = "on-demand",
    direct: bool = true,
    cancel_unavail: bool = true,
    bid_price: ?f64 = null,
    env: ?[]const u8 = null,
    onstart_cmd: ?[]const u8 = null,
};

pub const TargetConfig = struct {
    name: []const u8,
    provider: ProviderKind,
    app: []const u8 = "",
    image: []const u8 = "",
    vm_size: []const u8 = "",
    vm_memory: ?[]const u8 = null,
    region: ?[]const u8 = null,
    region_preference: ?[]const []const u8 = null,
    ssh_user: []const u8,
    ssh_identity_file: ?[]const u8 = null,
    startup_script: ?[]const u8 = null,
    fly: ?FlyTargetConfig = null,
    vast: ?VastTargetConfig = null,
};

pub const ConfigFile = struct {
    targets: []const TargetConfig = &.{},
};

pub const MachineRecord = struct {
    name: []const u8,
    target_name: ?[]const u8 = null,
    provider: ProviderKind,
    id: []const u8,
    machine_name: ?[]const u8 = null,
    provider_scope: ?[]const u8 = null,
    app: ?[]const u8 = null,
    host: []const u8,
    ssh_port: u16 = 22,
    ssh_identity_file: ?[]const u8 = null,
    region: ?[]const u8 = null,
    remote_state: ?[]const u8 = null,
    ssh_user: []const u8,
    status: LifecycleStatus,
    provider_metadata: ?std.json.Value = null,
};

pub const StateFile = struct {
    machines: []const MachineRecord = &.{},
};

pub fn providerName(provider: ProviderKind) []const u8 {
    return @tagName(provider);
}

pub fn statusName(status: LifecycleStatus) []const u8 {
    return @tagName(status);
}
