const std = @import("std");

pub fn defaultConfigPath() []const u8 {
    return "rove.json";
}

pub fn defaultStateDir(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.rove", .{home});
}

pub fn defaultStatePath(allocator: std.mem.Allocator) ![]u8 {
    const state_dir = try defaultStateDir(allocator);
    defer allocator.free(state_dir);

    return std.fmt.allocPrint(allocator, "{s}/state.json", .{state_dir});
}

pub fn defaultKnownHostsPath(allocator: std.mem.Allocator) ![]u8 {
    const state_dir = try defaultStateDir(allocator);
    defer allocator.free(state_dir);

    return std.fmt.allocPrint(allocator, "{s}/known_hosts", .{state_dir});
}

pub fn defaultManagedPrivateKeyPath(allocator: std.mem.Allocator) ![]u8 {
    const state_dir = try defaultStateDir(allocator);
    defer allocator.free(state_dir);

    return std.fmt.allocPrint(allocator, "{s}/id_ed25519", .{state_dir});
}

pub fn defaultManagedPublicKeyPath(allocator: std.mem.Allocator) ![]u8 {
    const private_key_path = try defaultManagedPrivateKeyPath(allocator);
    defer allocator.free(private_key_path);

    return std.fmt.allocPrint(allocator, "{s}.pub", .{private_key_path});
}

pub fn defaultGitAuthPrivateKeyPath(allocator: std.mem.Allocator) ![]u8 {
    const state_dir = try defaultStateDir(allocator);
    defer allocator.free(state_dir);

    return std.fmt.allocPrint(allocator, "{s}/git_id_ed25519", .{state_dir});
}

pub fn defaultGitAuthPublicKeyPath(allocator: std.mem.Allocator) ![]u8 {
    const private_key_path = try defaultGitAuthPrivateKeyPath(allocator);
    defer allocator.free(private_key_path);

    return std.fmt.allocPrint(allocator, "{s}.pub", .{private_key_path});
}

pub fn defaultLocalGhHostsPath(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.config/gh/hosts.yml", .{home});
}
