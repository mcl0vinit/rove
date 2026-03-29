const std = @import("std");
const model = @import("model.zig");
const paths = @import("paths.zig");

pub const Error = std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.Dir.AccessError ||
    std.json.ParseError(std.json.Scanner) ||
    error{
        DuplicateTarget,
        EmptyTargetName,
        MissingApp,
        MissingImage,
        MissingProfileInstallCommand,
        MissingProfilePath,
        MissingProfileRef,
        MissingProfileRepo,
        MissingTmuxCaptureScript,
        MissingVmSize,
        MissingSshUser,
        MissingStartupScript,
        MissingRegionPreference,
        TargetNotFound,
    };

const ValidationOptions = struct {
    check_startup_script_paths: bool = true,
};

pub fn load(
    allocator: std.mem.Allocator,
    path_override: ?[]const u8,
) Error!std.json.Parsed(model.ConfigFile) {
    const path = path_override orelse paths.defaultConfigPath();
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(contents);

    return parseSlice(allocator, contents, .{ .check_startup_script_paths = true });
}

pub fn parseSlice(
    allocator: std.mem.Allocator,
    contents: []const u8,
    validation_options: ValidationOptions,
) Error!std.json.Parsed(model.ConfigFile) {
    var parsed = try std.json.parseFromSlice(model.ConfigFile, allocator, contents, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    try validate(parsed.value.targets, validation_options);

    return parsed;
}

pub fn resolveTarget(
    file: *const model.ConfigFile,
    name: []const u8,
) Error!*const model.TargetConfig {
    for (file.targets) |*target| {
        if (std.mem.eql(u8, target.name, name)) {
            return target;
        }
    }

    return error.TargetNotFound;
}

fn validate(
    targets: []const model.TargetConfig,
    options: ValidationOptions,
) Error!void {
    for (targets, 0..) |target, index| {
        if (target.name.len == 0) return error.EmptyTargetName;
        if (target.app.len == 0) return error.MissingApp;
        if (target.image.len == 0) return error.MissingImage;
        if (target.vm_size.len == 0) return error.MissingVmSize;
        if (target.ssh_user.len == 0) return error.MissingSshUser;
        if (target.startup_script.len == 0) return error.MissingStartupScript;

        if (target.region_preference) |preference| {
            if (preference.len == 0) return error.MissingRegionPreference;
        }

        if (target.profile) |profile| {
            if (profile.repo.len == 0) return error.MissingProfileRepo;
            if (profile.ref) |ref| {
                if (ref.len == 0) return error.MissingProfileRef;
            }
            if (profile.path) |path| {
                if (path.len == 0) return error.MissingProfilePath;
            }
            if (profile.install_command) |install_command| {
                if (install_command.len == 0) return error.MissingProfileInstallCommand;
            }
        }

        switch (target.tmux.backend) {
            .shape => {},
            .hook, .auto => {
                const capture_script = target.tmux.capture_script orelse return error.MissingTmuxCaptureScript;
                if (capture_script.len == 0) return error.MissingTmuxCaptureScript;
            },
        }

        if (options.check_startup_script_paths) {
            try std.fs.cwd().access(target.startup_script, .{});
            if (target.tmux.backend == .hook) {
                try std.fs.cwd().access(target.tmux.capture_script.?, .{});
            }
        }

        for (targets[index + 1 ..]) |other| {
            if (std.mem.eql(u8, target.name, other.name)) {
                return error.DuplicateTarget;
            }
        }
    }
}

test "parse and resolve target" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "app": "devbox",
        \\      "image": "registry.fly.io/devbox:latest",
        \\      "vm_size": "shared-cpu-2x",
        \\      "ssh_user": "root",
        \\      "startup_script": "./scripts/bootstrap.sh"
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseSlice(allocator, contents, ValidationOptions{
        .check_startup_script_paths = false,
    });
    defer parsed.deinit();

    const target = try resolveTarget(&parsed.value, "devbox");
    try std.testing.expectEqualStrings("devbox", target.app);
    try std.testing.expectEqual(model.ProviderKind.fly, target.provider);
}

test "reject duplicate target names" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "app": "devbox",
        \\      "image": "registry.fly.io/devbox:latest",
        \\      "vm_size": "shared-cpu-2x",
        \\      "ssh_user": "root",
        \\      "startup_script": "./scripts/bootstrap.sh"
        \\    },
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "app": "devbox",
        \\      "image": "registry.fly.io/devbox:latest",
        \\      "vm_size": "shared-cpu-2x",
        \\      "ssh_user": "root",
        \\      "startup_script": "./scripts/bootstrap.sh"
        \\    }
        \\  ]
        \\}
    ;

    try std.testing.expectError(
        error.DuplicateTarget,
        parseSlice(allocator, contents, ValidationOptions{
            .check_startup_script_paths = false,
        }),
    );
}

test "parse target with profile" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "app": "devbox",
        \\      "image": "registry.fly.io/devbox:latest",
        \\      "vm_size": "shared-cpu-2x",
        \\      "ssh_user": "root",
        \\      "startup_script": "./scripts/bootstrap.sh",
        \\      "profile": {
        \\        "repo": "git@github.com:example/dotfiles.git",
        \\        "ref": "main",
        \\        "install_command": "./bin/bootstrap --apply"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseSlice(allocator, contents, ValidationOptions{
        .check_startup_script_paths = false,
    });
    defer parsed.deinit();

    const target = try resolveTarget(&parsed.value, "devbox");
    try std.testing.expect(target.profile != null);
    try std.testing.expectEqualStrings("git@github.com:example/dotfiles.git", target.profile.?.repo);
    try std.testing.expectEqualStrings("./bin/bootstrap --apply", target.profile.?.install_command.?);
}

test "parse target with auto tmux hook" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "app": "devbox",
        \\      "image": "registry.fly.io/devbox:latest",
        \\      "vm_size": "shared-cpu-2x",
        \\      "ssh_user": "root",
        \\      "startup_script": "./scripts/bootstrap.sh",
        \\      "tmux": {
        \\        "backend": "auto",
        \\        "capture_script": "/tmp/tmux-capture"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseSlice(allocator, contents, ValidationOptions{
        .check_startup_script_paths = false,
    });
    defer parsed.deinit();

    const target = try resolveTarget(&parsed.value, "devbox");
    try std.testing.expectEqual(model.TmuxBackendKind.auto, target.tmux.backend);
    try std.testing.expectEqualStrings("/tmp/tmux-capture", target.tmux.capture_script.?);
}

test "reject tmux hook config without capture script" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "targets": [
        \\    {
        \\      "name": "devbox",
        \\      "provider": "fly",
        \\      "app": "devbox",
        \\      "image": "registry.fly.io/devbox:latest",
        \\      "vm_size": "shared-cpu-2x",
        \\      "ssh_user": "root",
        \\      "startup_script": "./scripts/bootstrap.sh",
        \\      "tmux": {
        \\        "backend": "hook"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    try std.testing.expectError(
        error.MissingTmuxCaptureScript,
        parseSlice(allocator, contents, ValidationOptions{
            .check_startup_script_paths = false,
        }),
    );
}
