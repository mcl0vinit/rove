pub const ProviderKind = enum {
    fly,
};

pub const LifecycleStatus = enum {
    creating,
    provisioned,
    waiting_for_ssh,
    bootstrapping,
    applying_profile,
    offloading,
    ready,
    bootstrap_failed,
    profile_failed,
    offload_failed,
    provisioned_unreachable,
    destroying,
};

pub const ProfileConfig = struct {
    repo: []const u8,
    ref: ?[]const u8 = null,
    path: ?[]const u8 = null,
    install_command: ?[]const u8 = null,
};

pub const TmuxBackendKind = enum {
    shape,
    hook,
    auto,
};

pub const TmuxConfig = struct {
    backend: TmuxBackendKind = .shape,
    capture_script: ?[]const u8 = null,
};

pub const TargetConfig = struct {
    name: []const u8,
    provider: ProviderKind,
    app: []const u8,
    image: []const u8,
    vm_size: []const u8,
    region: ?[]const u8 = null,
    region_preference: ?[]const []const u8 = null,
    ssh_user: []const u8,
    startup_script: []const u8,
    profile: ?ProfileConfig = null,
    tmux: TmuxConfig = .{},
};

pub const ConfigFile = struct {
    targets: []const TargetConfig = &.{},
};

pub const WorkspaceRecord = struct {
    local_path: []const u8,
    remote_path: []const u8,
    tmux_session: ?[]const u8 = null,
};

pub const MachineRecord = struct {
    name: []const u8,
    target_name: ?[]const u8 = null,
    provider: ProviderKind,
    id: []const u8,
    machine_name: ?[]const u8 = null,
    app: ?[]const u8 = null,
    host: []const u8,
    region: ?[]const u8 = null,
    ssh_user: []const u8,
    workspace: ?WorkspaceRecord = null,
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
