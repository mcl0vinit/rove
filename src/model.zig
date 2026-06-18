pub const ProviderKind = enum {
    fly,
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
    region: ?[]const u8 = null,
    region_preference: ?[]const []const u8 = null,
};

pub const TargetConfig = struct {
    name: []const u8,
    provider: ProviderKind,
    app: []const u8 = "",
    image: []const u8 = "",
    vm_size: []const u8 = "",
    region: ?[]const u8 = null,
    region_preference: ?[]const []const u8 = null,
    ssh_user: []const u8,
    startup_script: ?[]const u8 = null,
    fly: ?FlyTargetConfig = null,
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
    region: ?[]const u8 = null,
    remote_state: ?[]const u8 = null,
    ssh_user: []const u8,
    status: LifecycleStatus,
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
