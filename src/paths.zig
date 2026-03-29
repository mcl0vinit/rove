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
