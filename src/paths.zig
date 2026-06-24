const std = @import("std");

pub fn defaultConfigPath() []const u8 {
    return "rove.json";
}

pub fn defaultUserConfigPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg_config_home| {
        defer allocator.free(xdg_config_home);

        if (xdg_config_home.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/rove/rove.json", .{xdg_config_home});
        }
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    return std.fmt.allocPrint(allocator, "{s}/.config/rove/rove.json", .{home});
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

pub fn expandUserPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') {
        return allocator.dupe(u8, path);
    }

    if (path.len > 1 and path[1] != '/') {
        return allocator.dupe(u8, path);
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    if (path.len == 1) {
        return allocator.dupe(u8, home);
    }

    return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
}
