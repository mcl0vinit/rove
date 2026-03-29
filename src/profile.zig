const std = @import("std");
const model = @import("model.zig");
const shell = @import("shell.zig");
const ssh = @import("ssh.zig");

pub fn apply(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    profile: model.ProfileConfig,
) !void {
    const command = try buildApplyCommand(allocator, profile);
    defer allocator.free(command);

    const result = try ssh.runBatchCommand(allocator, machine, command);
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stdout.len > 0) {
            std.debug.print("[error] profile apply stdout\n{s}", .{result.stdout});
        }
        if (result.stderr.len > 0) {
            std.debug.print("[error] profile apply stderr\n{s}", .{result.stderr});
        }
        return error.CommandFailed;
    }
}

pub fn resolvedPath(profile: model.ProfileConfig) []const u8 {
    return profile.path orelse "$HOME/.local/share/rove/profiles/default";
}

fn buildApplyCommand(
    allocator: std.mem.Allocator,
    profile: model.ProfileConfig,
) ![]u8 {
    const repo_quoted = try shell.quote(allocator, profile.repo);
    defer allocator.free(repo_quoted);

    const ref_quoted = try shell.quote(allocator, profile.ref orelse "HEAD");
    defer allocator.free(ref_quoted);

    const path_assignment = try pathAssignmentValue(allocator, profile);
    defer allocator.free(path_assignment);

    var command: std.Io.Writer.Allocating = .init(allocator);
    defer command.deinit();

    try command.writer.print(
        \\set -euo pipefail
        \\profile_repo={s}
        \\profile_ref={s}
        \\profile_dir={s}
        \\mkdir -p "$(dirname "$profile_dir")"
        \\if [[ -d "$profile_dir/.git" ]]; then
        \\  git -C "$profile_dir" remote set-url origin "$profile_repo"
        \\else
        \\  rm -rf "$profile_dir"
        \\  git init "$profile_dir" >/dev/null
        \\  git -C "$profile_dir" remote add origin "$profile_repo"
        \\fi
        \\git -C "$profile_dir" fetch --depth 1 origin "$profile_ref"
        \\git -C "$profile_dir" checkout --force FETCH_HEAD >/dev/null
        \\
    , .{ repo_quoted, ref_quoted, path_assignment });

    if (profile.install_command) |install_command| {
        const install_command_quoted = try shell.quote(allocator, install_command);
        defer allocator.free(install_command_quoted);

        try command.writer.print(
            \\profile_install_command={s}
            \\cd "$profile_dir"
            \\eval "$profile_install_command"
            \\
        , .{install_command_quoted});
    }

    return allocator.dupe(u8, command.written());
}

fn pathAssignmentValue(
    allocator: std.mem.Allocator,
    profile: model.ProfileConfig,
) ![]u8 {
    if (profile.path) |path| {
        return shell.quote(allocator, path);
    }

    return allocator.dupe(u8, "\"$HOME/.local/share/rove/profiles/default\"");
}

test "resolved path defaults to rove profile dir" {
    const profile = model.ProfileConfig{
        .repo = "git@github.com:example/dotfiles.git",
    };

    try std.testing.expectEqualStrings("$HOME/.local/share/rove/profiles/default", resolvedPath(profile));
}

test "default path assignment expands HOME on the remote shell" {
    const allocator = std.testing.allocator;
    const path_value = try pathAssignmentValue(allocator, .{
        .repo = "git@github.com:example/dotfiles.git",
    });
    defer allocator.free(path_value);

    try std.testing.expectEqualStrings("\"$HOME/.local/share/rove/profiles/default\"", path_value);
}

test "build command includes install command when configured" {
    const allocator = std.testing.allocator;
    const command = try buildApplyCommand(allocator, .{
        .repo = "git@github.com:example/dotfiles.git",
        .ref = "main",
        .install_command = "./bin/bootstrap --apply",
    });
    defer allocator.free(command);

    try std.testing.expect(std.mem.indexOf(u8, command, "git -C \"$profile_dir\" fetch --depth 1 origin \"$profile_ref\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "profile_install_command='./bin/bootstrap --apply'") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "eval \"$profile_install_command\"") != null);
}
