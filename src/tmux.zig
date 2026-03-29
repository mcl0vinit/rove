const std = @import("std");
const exec = @import("exec.zig");
const model = @import("model.zig");
const shell = @import("shell.zig");
const ssh = @import("ssh.zig");
const workspace = @import("workspace.zig");

const ArrayList = std.ArrayListUnmanaged;

pub const AppliedBackend = enum {
    shape,
    hook,
    tracked,
};

pub const RestorePlan = struct {
    session_name: []const u8,
    remote_script: []const u8,
    attach_command: ?[]const u8 = null,

    pub fn deinit(self: RestorePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.session_name);
        allocator.free(self.remote_script);
        if (self.attach_command) |attach_command| {
            allocator.free(attach_command);
        }
    }
};

pub const PlannedRestore = struct {
    backend: AppliedBackend,
    restore: RestorePlan,

    pub fn deinit(self: PlannedRestore, allocator: std.mem.Allocator) void {
        self.restore.deinit(allocator);
    }
};

const HookPlanFile = struct {
    session_name: []const u8,
    remote_script: []const u8,
    attach_command: ?[]const u8 = null,
};

pub const PaneSnapshot = struct {
    cwd: []const u8,
    active: bool,
};

pub const WindowSnapshot = struct {
    name: []const u8,
    layout: []const u8,
    panes: []const PaneSnapshot,
    active: bool,
    active_pane: usize,

    fn deinit(self: WindowSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.layout);
        for (self.panes) |pane| {
            allocator.free(pane.cwd);
        }
        allocator.free(self.panes);
    }
};

pub const SessionSnapshot = struct {
    name: []const u8,
    windows: []const WindowSnapshot,

    pub fn deinit(self: SessionSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.windows) |window| {
            window.deinit(allocator);
        }
        allocator.free(self.windows);
    }
};

pub fn planOffload(
    allocator: std.mem.Allocator,
    tmux_config: model.TmuxConfig,
    resolved: workspace.ResolvedWorkspace,
) !PlannedRestore {
    return switch (tmux_config.backend) {
        .shape => .{
            .backend = .shape,
            .restore = try planShapeRestore(allocator, resolved),
        },
        .hook => .{
            .backend = .hook,
            .restore = try planHookRestore(allocator, tmux_config, resolved),
        },
        .auto => planAutoRestore(allocator, tmux_config, resolved),
    };
}

pub fn backendName(backend: AppliedBackend) []const u8 {
    return @tagName(backend);
}

pub fn applyRemote(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    plan: RestorePlan,
) !void {
    const result = try ssh.runBatchCommand(allocator, machine, plan.remote_script);
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stderr.len > 0) {
            std.debug.print("[error] tmux restore failed\n{s}", .{result.stderr});
        }
        return error.CommandFailed;
    }
}

pub fn attachCommand(
    allocator: std.mem.Allocator,
    plan: RestorePlan,
) ![]u8 {
    if (plan.attach_command) |attach_command| {
        return allocator.dupe(u8, attach_command);
    }

    const quoted = try shell.quote(allocator, plan.session_name);
    defer allocator.free(quoted);

    return std.fmt.allocPrint(allocator, "tmux attach -t {s}", .{quoted});
}

pub fn planTrackedWorkspaceSession(
    allocator: std.mem.Allocator,
    resolved: workspace.ResolvedWorkspace,
    recorded_session: ?[]const u8,
) !RestorePlan {
    const session_name = recorded_session orelse resolved.name;
    const quoted_session = try shell.quote(allocator, session_name);
    defer allocator.free(quoted_session);

    const quoted_remote_root = try workspace.quoteRemotePath(allocator, resolved.remote_root);
    defer allocator.free(quoted_remote_root);

    return .{
        .session_name = try allocator.dupe(u8, session_name),
        .remote_script = try std.fmt.allocPrint(
            allocator,
            \\set -euo pipefail
            \\session={s}
            \\if ! tmux has-session -t "$session" 2>/dev/null; then
            \\  tmux new-session -d -s "$session" -c {s}
            \\fi
            \\
        ,
            .{ quoted_session, quoted_remote_root },
        ),
    };
}

fn captureCurrentOrDefault(
    allocator: std.mem.Allocator,
    resolved: workspace.ResolvedWorkspace,
) !SessionSnapshot {
    const tmux_env = std.process.getEnvVarOwned(allocator, "TMUX") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (tmux_env) |value| allocator.free(value);

    if (tmux_env == null) {
        return defaultSnapshot(allocator, resolved);
    }

    const session_name = try currentSessionName(allocator);
    errdefer allocator.free(session_name);

    const windows = try captureWindows(allocator, session_name);
    errdefer {
        for (windows) |window| window.deinit(allocator);
        allocator.free(windows);
    }

    return .{
        .name = session_name,
        .windows = windows,
    };
}

fn currentSessionName(allocator: std.mem.Allocator) ![]u8 {
    const result = try exec.run(allocator, &.{ "tmux", "display-message", "-p", "#S" });
    defer result.deinit(allocator);

    if (!result.succeeded()) return error.CommandFailed;
    return allocator.dupe(u8, std.mem.trimRight(u8, result.stdout, "\r\n"));
}

fn captureWindows(
    allocator: std.mem.Allocator,
    session_name: []const u8,
) ![]WindowSnapshot {
    const result = try exec.run(allocator, &.{
        "tmux",
        "list-windows",
        "-t",
        session_name,
        "-F",
        "#{window_id}|#{window_name}|#{window_layout}|#{window_active}",
    });
    defer result.deinit(allocator);

    if (!result.succeeded()) return error.CommandFailed;

    var windows: ArrayList(WindowSnapshot) = .empty;
    errdefer {
        for (windows.items) |window| window.deinit(allocator);
        windows.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, result.stdout, "\r\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, line, '|');
        const window_id = parts.next() orelse return error.InvalidTmuxOutput;
        const window_name = parts.next() orelse return error.InvalidTmuxOutput;
        const layout = parts.next() orelse return error.InvalidTmuxOutput;
        const active = parts.next() orelse return error.InvalidTmuxOutput;

        var panes = try capturePanes(allocator, window_id);
        errdefer {
            for (panes.items) |pane| allocator.free(pane.cwd);
            panes.deinit(allocator);
        }

        const window = WindowSnapshot{
            .name = try allocator.dupe(u8, window_name),
            .layout = try allocator.dupe(u8, layout),
            .panes = try panes.toOwnedSlice(allocator),
            .active = active[0] == '1',
            .active_pane = panesActiveIndex(panes.items),
        };
        try windows.append(allocator, window);
    }

    return windows.toOwnedSlice(allocator);
}

fn capturePanes(
    allocator: std.mem.Allocator,
    window_id: []const u8,
) !ArrayList(PaneSnapshot) {
    const result = try exec.run(allocator, &.{
        "tmux",
        "list-panes",
        "-t",
        window_id,
        "-F",
        "#{pane_current_path}|#{pane_active}",
    });
    defer result.deinit(allocator);

    if (!result.succeeded()) return error.CommandFailed;

    var panes: ArrayList(PaneSnapshot) = .empty;
    errdefer {
        for (panes.items) |pane| allocator.free(pane.cwd);
        panes.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, result.stdout, "\r\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, line, '|');
        const cwd = parts.next() orelse return error.InvalidTmuxOutput;
        const active = parts.next() orelse return error.InvalidTmuxOutput;

        try panes.append(allocator, .{
            .cwd = try allocator.dupe(u8, cwd),
            .active = active[0] == '1',
        });
    }

    return panes;
}

fn panesActiveIndex(panes: []const PaneSnapshot) usize {
    for (panes, 0..) |pane, index| {
        if (pane.active) return index;
    }

    return 0;
}

fn defaultSnapshot(
    allocator: std.mem.Allocator,
    resolved: workspace.ResolvedWorkspace,
) !SessionSnapshot {
    const pane = PaneSnapshot{
        .cwd = try allocator.dupe(u8, resolved.current_dir),
        .active = true,
    };

    const panes = try allocator.alloc(PaneSnapshot, 1);
    panes[0] = pane;

    const windows = try allocator.alloc(WindowSnapshot, 1);
    windows[0] = .{
        .name = try allocator.dupe(u8, resolved.name),
        .layout = try allocator.dupe(u8, "even-horizontal"),
        .panes = panes,
        .active = true,
        .active_pane = 0,
    };

    return .{
        .name = try allocator.dupe(u8, resolved.name),
        .windows = windows,
    };
}

fn planAutoRestore(
    allocator: std.mem.Allocator,
    tmux_config: model.TmuxConfig,
    resolved: workspace.ResolvedWorkspace,
) !PlannedRestore {
    const restore = planHookRestore(allocator, tmux_config, resolved) catch |err| switch (err) {
        error.MissingCaptureScript,
        error.HookScriptUnavailable,
        error.CaptureScriptFailed,
        error.InvalidHookPlan,
        => return .{
            .backend = .shape,
            .restore = try planShapeRestore(allocator, resolved),
        },
        else => return err,
    };

    return .{
        .backend = .hook,
        .restore = restore,
    };
}

fn planShapeRestore(
    allocator: std.mem.Allocator,
    resolved: workspace.ResolvedWorkspace,
) !RestorePlan {
    const snapshot = try captureCurrentOrDefault(allocator, resolved);
    defer snapshot.deinit(allocator);

    return .{
        .session_name = try allocator.dupe(u8, snapshot.name),
        .remote_script = try buildShapeRestoreCommand(allocator, snapshot, resolved),
    };
}

fn planHookRestore(
    allocator: std.mem.Allocator,
    tmux_config: model.TmuxConfig,
    resolved: workspace.ResolvedWorkspace,
) !RestorePlan {
    const capture_script = tmux_config.capture_script orelse return error.MissingCaptureScript;
    if (capture_script.len == 0) return error.MissingCaptureScript;

    const remote_current_dir = try workspace.mapLocalPath(allocator, resolved, resolved.current_dir);
    defer allocator.free(remote_current_dir);

    const result = exec.run(allocator, &.{
        capture_script,
        resolved.local_root,
        resolved.current_dir,
        resolved.remote_root,
        remote_current_dir,
    }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.HookScriptUnavailable,
        else => return err,
    };
    defer result.deinit(allocator);

    if (!result.succeeded()) {
        if (result.stderr.len > 0) {
            std.debug.print("[error] tmux hook capture failed\n{s}", .{result.stderr});
        }
        return error.CaptureScriptFailed;
    }

    return restorePlanFromJson(allocator, result.stdout);
}

fn restorePlanFromJson(
    allocator: std.mem.Allocator,
    json_slice: []const u8,
) !RestorePlan {
    const trimmed = std.mem.trim(u8, json_slice, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidHookPlan;

    var parsed = std.json.parseFromSlice(HookPlanFile, allocator, trimmed, .{
        .allocate = .alloc_always,
    }) catch {
        return error.InvalidHookPlan;
    };
    defer parsed.deinit();

    if (parsed.value.session_name.len == 0) return error.InvalidHookPlan;
    if (parsed.value.remote_script.len == 0) return error.InvalidHookPlan;
    if (parsed.value.attach_command) |attach_command| {
        if (attach_command.len == 0) return error.InvalidHookPlan;
    }

    return .{
        .session_name = try allocator.dupe(u8, parsed.value.session_name),
        .remote_script = try allocator.dupe(u8, parsed.value.remote_script),
        .attach_command = if (parsed.value.attach_command) |attach_command|
            try allocator.dupe(u8, attach_command)
        else
            null,
    };
}

fn buildShapeRestoreCommand(
    allocator: std.mem.Allocator,
    snapshot: SessionSnapshot,
    resolved: workspace.ResolvedWorkspace,
) ![]u8 {
    const session_name = try shell.quote(allocator, snapshot.name);
    defer allocator.free(session_name);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.print(
        \\set -euo pipefail
        \\session={s}
        \\if tmux has-session -t "$session" 2>/dev/null; then
        \\  tmux kill-session -t "$session"
        \\fi
        \\
    , .{session_name});

    for (snapshot.windows, 0..) |window, window_index| {
        const window_name = try shell.quote(allocator, window.name);
        defer allocator.free(window_name);

        const first_pane_remote = try workspace.mapLocalPath(allocator, resolved, window.panes[0].cwd);
        defer allocator.free(first_pane_remote);

        const first_pane_cwd = try workspace.quoteRemotePath(allocator, first_pane_remote);
        defer allocator.free(first_pane_cwd);

        if (window_index == 0) {
            try writer.writer.print(
                \\tmux new-session -d -s "$session" -n {s} -c {s}
                \\
            , .{ window_name, first_pane_cwd });
        } else {
            try writer.writer.print(
                \\tmux new-window -d -t "$session" -n {s} -c {s}
                \\
            , .{ window_name, first_pane_cwd });
        }

        for (window.panes[1..]) |pane| {
            const remote_path = try workspace.mapLocalPath(allocator, resolved, pane.cwd);
            defer allocator.free(remote_path);

            const quoted_remote = try workspace.quoteRemotePath(allocator, remote_path);
            defer allocator.free(quoted_remote);

            try writer.writer.print(
                \\tmux split-window -d -t "$session":{s} -c {s}
                \\
            , .{ window_name, quoted_remote });
        }

        const layout = try shell.quote(allocator, window.layout);
        defer allocator.free(layout);

        try writer.writer.print(
            \\tmux select-layout -t "$session":{s} {s} >/dev/null
            \\active_pane_id=$(tmux list-panes -t "$session":{s} -F '#{{pane_id}}' | sed -n '{d}p')
            \\if [[ -n "$active_pane_id" ]]; then
            \\  tmux select-pane -t "$active_pane_id"
            \\fi
            \\
        , .{ window_name, layout, window_name, window.active_pane + 1 });
    }

    for (snapshot.windows) |window| {
        if (!window.active) continue;

        const active_name = try shell.quote(allocator, window.name);
        defer allocator.free(active_name);

        try writer.writer.print(
            \\tmux select-window -t "$session":{s}
            \\
        , .{active_name});
        break;
    }

    return allocator.dupe(u8, writer.written());
}

test "default snapshot uses repo name" {
    const allocator = std.testing.allocator;
    const resolved = workspace.ResolvedWorkspace{
        .local_root = try allocator.dupe(u8, "/tmp/project"),
        .current_dir = try allocator.dupe(u8, "/tmp/project"),
        .remote_root = try allocator.dupe(u8, "$HOME/work/project"),
        .name = try allocator.dupe(u8, "project"),
    };
    defer resolved.deinit(allocator);

    const snapshot = try defaultSnapshot(allocator, resolved);
    defer snapshot.deinit(allocator);

    try std.testing.expectEqualStrings("project", snapshot.name);
    try std.testing.expectEqual(@as(usize, 1), snapshot.windows.len);
}

test "restore plan parses hook json" {
    const allocator = std.testing.allocator;
    const plan = try restorePlanFromJson(allocator,
        \\{
        \\  "session_name": "main",
        \\  "remote_script": "echo restore",
        \\  "attach_command": "tmux attach -t main"
        \\}
    );
    defer plan.deinit(allocator);

    try std.testing.expectEqualStrings("main", plan.session_name);
    try std.testing.expectEqualStrings("echo restore", plan.remote_script);
    try std.testing.expectEqualStrings("tmux attach -t main", plan.attach_command.?);
}

test "auto tmux backend falls back to shape when hook is unavailable" {
    const allocator = std.testing.allocator;
    const resolved = workspace.ResolvedWorkspace{
        .local_root = try allocator.dupe(u8, "/tmp/project"),
        .current_dir = try allocator.dupe(u8, "/tmp/project"),
        .remote_root = try allocator.dupe(u8, "$HOME/work/project"),
        .name = try allocator.dupe(u8, "project"),
    };
    defer resolved.deinit(allocator);

    const planned = try planOffload(allocator, .{
        .backend = .auto,
        .capture_script = "/tmp/this-hook-does-not-exist",
    }, resolved);
    defer planned.deinit(allocator);

    try std.testing.expectEqual(AppliedBackend.shape, planned.backend);
    try std.testing.expectEqualStrings("project", planned.restore.session_name);
}
