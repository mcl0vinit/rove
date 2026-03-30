const std = @import("std");
const exec = @import("exec.zig");
const keys = @import("keys.zig");
const model = @import("model.zig");
const paths = @import("paths.zig");
const shell = @import("shell.zig");
const ssh = @import("ssh.zig");

pub const SyncResult = struct {
    public_key: []u8,
    gh_config_synced: bool = false,
    git_identity_synced: bool = false,

    pub fn deinit(self: SyncResult, allocator: std.mem.Allocator) void {
        allocator.free(self.public_key);
    }
};

pub fn syncGitHubAccess(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) !SyncResult {
    const git_key = try keys.ensureGitAuthKeyPair(allocator);
    defer git_key.deinit(allocator);

    const remote_home = try remoteHome(allocator, machine);
    defer allocator.free(remote_home);

    const remote_private_key = try std.fmt.allocPrint(allocator, "{s}/.ssh/rove_git_ed25519", .{remote_home});
    defer allocator.free(remote_private_key);

    const remote_public_key = try std.fmt.allocPrint(allocator, "{s}.pub", .{remote_private_key});
    defer allocator.free(remote_public_key);

    try ssh.uploadFile(allocator, machine, git_key.private_key_path, remote_private_key);
    try ssh.uploadFile(allocator, machine, git_key.public_key_path, remote_public_key);

    const local_gh_hosts = try localGhHostsPath(allocator);
    defer if (local_gh_hosts) |path| allocator.free(path);

    const remote_gh_hosts = try std.fmt.allocPrint(allocator, "{s}/.config/gh/hosts.yml", .{remote_home});
    defer allocator.free(remote_gh_hosts);

    var gh_config_synced = false;
    if (local_gh_hosts) |path| {
        try ssh.uploadFile(allocator, machine, path, remote_gh_hosts);
        gh_config_synced = true;
    }

    const git_user_name = try localGitConfig(allocator, "user.name");
    defer if (git_user_name) |value| allocator.free(value);

    const git_user_email = try localGitConfig(allocator, "user.email");
    defer if (git_user_email) |value| allocator.free(value);

    const quoted_remote_home = try shell.quote(allocator, remote_home);
    defer allocator.free(quoted_remote_home);

    const quoted_remote_private_key = try shell.quote(allocator, remote_private_key);
    defer allocator.free(quoted_remote_private_key);

    const quoted_remote_public_key = try shell.quote(allocator, remote_public_key);
    defer allocator.free(quoted_remote_public_key);

    const quoted_remote_gh_hosts = try shell.quote(allocator, remote_gh_hosts);
    defer allocator.free(quoted_remote_gh_hosts);

    const git_user_name_cmd = if (git_user_name) |value| cmd: {
        const quoted = try shell.quote(allocator, value);
        defer allocator.free(quoted);
        break :cmd try std.fmt.allocPrint(allocator, "git config --global user.name {s}\n", .{quoted});
    } else try allocator.dupe(u8, "");
    defer allocator.free(git_user_name_cmd);

    const git_user_email_cmd = if (git_user_email) |value| cmd: {
        const quoted = try shell.quote(allocator, value);
        defer allocator.free(quoted);
        break :cmd try std.fmt.allocPrint(allocator, "git config --global user.email {s}\n", .{quoted});
    } else try allocator.dupe(u8, "");
    defer allocator.free(git_user_email_cmd);

    const remote_command = try std.fmt.allocPrint(
        allocator,
        \\mkdir -p {0s}/.ssh {0s}/.config/gh
        \\chmod 700 {0s}/.ssh
        \\touch {0s}/.ssh/config {0s}/.ssh/known_hosts
        \\chmod 600 {1s} {0s}/.ssh/config {0s}/.ssh/known_hosts
        \\chmod 644 {2s}
        \\tmp_config="$(mktemp)"
        \\sed '/# >>> rove github >>>/,/# <<< rove github <<</d' {0s}/.ssh/config > "${{tmp_config}}" || true
        \\cat >> "${{tmp_config}}" <<'EOF'
        \\# >>> rove github >>>
        \\Host github.com
        \\  HostName github.com
        \\  User git
        \\  IdentityFile ~/.ssh/rove_git_ed25519
        \\  IdentitiesOnly yes
        \\# <<< rove github <<<
        \\EOF
        \\mv "${{tmp_config}}" {0s}/.ssh/config
        \\chmod 600 {0s}/.ssh/config
        \\ssh-keyscan -H github.com >> {0s}/.ssh/known_hosts 2>/dev/null || true
        \\sort -u {0s}/.ssh/known_hosts -o {0s}/.ssh/known_hosts 2>/dev/null || true
        \\chmod 600 {0s}/.ssh/known_hosts
        \\if [[ -f {3s} ]]; then chmod 600 {3s}; fi
        \\if command -v gh >/dev/null 2>&1 && [[ -f {3s} ]]; then
        \\  gh auth setup-git >/dev/null 2>&1 || true
        \\fi
        \\{4s}{5s}
    ,
        .{
            quoted_remote_home,
            quoted_remote_private_key,
            quoted_remote_public_key,
            quoted_remote_gh_hosts,
            git_user_name_cmd,
            git_user_email_cmd,
        },
    );
    defer allocator.free(remote_command);

    const result = try ssh.runBatchCommand(allocator, machine, remote_command);
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stdout.len > 0) {
            std.debug.print("[error] remote auth stdout\n{s}", .{result.stdout});
        }
        if (result.stderr.len > 0) {
            std.debug.print("[error] remote auth stderr\n{s}", .{result.stderr});
        }
        return error.CommandFailed;
    }

    return .{
        .public_key = try allocator.dupe(u8, git_key.public_key),
        .gh_config_synced = gh_config_synced,
        .git_identity_synced = git_user_name != null or git_user_email != null,
    };
}

pub fn localGhHostsPath(
    allocator: std.mem.Allocator,
) !?[]u8 {
    const path = try paths.defaultLocalGhHostsPath(allocator);
    errdefer allocator.free(path);

    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(path);
            return null;
        },
        else => return err,
    };

    return path;
}

pub fn localGhAuthAvailable(allocator: std.mem.Allocator) !bool {
    if (try localGhHostsPath(allocator)) |path| {
        allocator.free(path);
        return true;
    }

    const result = exec.run(allocator, &.{ "gh", "auth", "token" }) catch {
        return false;
    };
    defer result.deinit(allocator);

    return result.succeeded() and std.mem.trim(u8, result.stdout, "\r\n\t ").len > 0;
}

fn localGitConfig(
    allocator: std.mem.Allocator,
    key: []const u8,
) !?[]u8 {
    const result = exec.run(allocator, &.{ "git", "config", "--global", key }) catch {
        return null;
    };
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        return null;
    }

    const trimmed = std.mem.trim(u8, result.stdout, "\r\n\t ");
    if (trimmed.len == 0) {
        return null;
    }

    return try allocator.dupe(u8, trimmed);
}

fn remoteHome(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
) ![]u8 {
    if (std.mem.eql(u8, machine.ssh_user, "root")) {
        return allocator.dupe(u8, "/root");
    }

    return std.fmt.allocPrint(allocator, "/home/{s}", .{machine.ssh_user});
}

test "local gh hosts path returns null when missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const previous = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(previous);
    const tmp_home = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_home);

    try std.posix.setenv("HOME", tmp_home, true);
    defer std.posix.setenv("HOME", previous, true) catch unreachable;

    const path = try localGhHostsPath(allocator);
    defer if (path) |value| allocator.free(value);

    try std.testing.expect(path == null);
}
