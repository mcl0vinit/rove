const std = @import("std");
const exec = @import("exec.zig");
const paths = @import("paths.zig");

pub const ManagedKeyPair = struct {
    private_key_path: []u8,
    public_key_path: []u8,
    public_key: []u8,

    pub fn deinit(self: ManagedKeyPair, allocator: std.mem.Allocator) void {
        allocator.free(self.private_key_path);
        allocator.free(self.public_key_path);
        allocator.free(self.public_key);
    }
};

pub fn ensureManagedKeyPair(allocator: std.mem.Allocator) !ManagedKeyPair {
    const private_key_path = try paths.defaultManagedPrivateKeyPath(allocator);
    errdefer allocator.free(private_key_path);

    const public_key_path = try paths.defaultManagedPublicKeyPath(allocator);
    errdefer allocator.free(public_key_path);

    if (std.fs.path.dirname(private_key_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    try ensureKeyMaterial(allocator, private_key_path, public_key_path, "rove-managed");

    const public_key = try readTrimmedFile(allocator, public_key_path);
    errdefer allocator.free(public_key);

    return .{
        .private_key_path = private_key_path,
        .public_key_path = public_key_path,
        .public_key = public_key,
    };
}

pub fn ensureGitAuthKeyPair(allocator: std.mem.Allocator) !ManagedKeyPair {
    const private_key_path = try paths.defaultGitAuthPrivateKeyPath(allocator);
    errdefer allocator.free(private_key_path);

    const public_key_path = try paths.defaultGitAuthPublicKeyPath(allocator);
    errdefer allocator.free(public_key_path);

    if (std.fs.path.dirname(private_key_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    try ensureKeyMaterial(allocator, private_key_path, public_key_path, "rove-github");

    const public_key = try readTrimmedFile(allocator, public_key_path);
    errdefer allocator.free(public_key);

    return .{
        .private_key_path = private_key_path,
        .public_key_path = public_key_path,
        .public_key = public_key,
    };
}

fn ensureKeyMaterial(
    allocator: std.mem.Allocator,
    private_key_path: []const u8,
    public_key_path: []const u8,
    comment: []const u8,
) !void {
    const private_exists = fileExists(private_key_path);
    const public_exists = fileExists(public_key_path);

    if (!private_exists and !public_exists) {
        const result = try exec.run(allocator, &.{
            "ssh-keygen",
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            comment,
            "-f",
            private_key_path,
        });
        defer result.deinit(allocator);

        if (!result.succeeded()) {
            if (result.stderr.len > 0) {
                std.debug.print("[error] failed to generate managed SSH key\n{s}", .{result.stderr});
            }
            return error.CommandFailed;
        }

        return;
    }

    if (private_exists and !public_exists) {
        const result = try exec.run(allocator, &.{
            "ssh-keygen",
            "-q",
            "-y",
            "-f",
            private_key_path,
        });
        defer result.deinit(allocator);

        if (!result.succeeded()) {
            if (result.stderr.len > 0) {
                std.debug.print("[error] failed to derive managed SSH public key\n{s}", .{result.stderr});
            }
            return error.CommandFailed;
        }

        try writeFile(public_key_path, result.stdout);
        return;
    }

    if (!private_exists and public_exists) {
        return error.MissingManagedPrivateKey;
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn readTrimmedFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    defer allocator.free(contents);

    return allocator.dupe(u8, std.mem.trimRight(u8, contents, "\r\n"));
}

fn writeFile(
    path: []const u8,
    contents: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(contents);
}
