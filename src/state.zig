const std = @import("std");
const model = @import("model.zig");
const paths = @import("paths.zig");

const ArrayList = std.ArrayListUnmanaged;

pub const LoadedState = struct {
    parsed: ?std.json.Parsed(model.StateFile) = null,
    value: model.StateFile = .{},

    pub fn deinit(self: *LoadedState) void {
        if (self.parsed) |*parsed| {
            parsed.deinit();
        }
    }
};

pub fn loadOrEmpty(
    allocator: std.mem.Allocator,
    path_override: ?[]const u8,
) !LoadedState {
    const owned_path = if (path_override) |path|
        try allocator.dupe(u8, path)
    else
        try paths.defaultStatePath(allocator);
    defer allocator.free(owned_path);

    const contents = std.fs.cwd().readFileAlloc(allocator, owned_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(model.StateFile, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();

    return .{
        .parsed = parsed,
        .value = parsed.value,
    };
}

pub fn findMachine(
    file: *const model.StateFile,
    name: []const u8,
) ?*const model.MachineRecord {
    for (file.machines) |*machine| {
        if (std.mem.eql(u8, machine.name, name)) {
            return machine;
        }
    }

    return null;
}

pub fn findMachineById(
    file: *const model.StateFile,
    id: []const u8,
) ?*const model.MachineRecord {
    for (file.machines) |*machine| {
        if (std.mem.eql(u8, machine.id, id)) {
            return machine;
        }
    }

    return null;
}

pub fn save(
    allocator: std.mem.Allocator,
    file: model.StateFile,
    path_override: ?[]const u8,
) !void {
    const owned_path = if (path_override) |path|
        try allocator.dupe(u8, path)
    else
        try paths.defaultStatePath(allocator);
    defer allocator.free(owned_path);

    if (std.fs.path.dirname(owned_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try std.json.Stringify.value(file, .{ .whitespace = .indent_2 }, &writer.writer);

    var out = try std.fs.cwd().createFile(owned_path, .{});
    defer out.close();

    try out.writeAll(writer.written());
    try out.writeAll("\n");
}

pub fn upsertMachine(
    allocator: std.mem.Allocator,
    machine: model.MachineRecord,
    path_override: ?[]const u8,
) !void {
    var loaded = try loadOrEmpty(allocator, path_override);
    defer loaded.deinit();

    var machines: ArrayList(model.MachineRecord) = .empty;
    defer machines.deinit(allocator);

    try machines.appendSlice(allocator, loaded.value.machines);

    for (machines.items) |*existing| {
        if (std.mem.eql(u8, existing.name, machine.name)) {
            existing.* = machine;
            try save(allocator, .{ .machines = machines.items }, path_override);
            return;
        }
    }

    try machines.append(allocator, machine);
    try save(allocator, .{ .machines = machines.items }, path_override);
}

pub fn removeMachine(
    allocator: std.mem.Allocator,
    name: []const u8,
    path_override: ?[]const u8,
) !bool {
    var loaded = try loadOrEmpty(allocator, path_override);
    defer loaded.deinit();

    var machines: ArrayList(model.MachineRecord) = .empty;
    defer machines.deinit(allocator);

    for (loaded.value.machines) |machine| {
        if (std.mem.eql(u8, machine.name, name)) continue;
        try machines.append(allocator, machine);
    }

    if (machines.items.len == loaded.value.machines.len) {
        return false;
    }

    try save(allocator, .{ .machines = machines.items }, path_override);
    return true;
}

test "load empty state when file is missing" {
    const allocator = std.testing.allocator;
    var loaded = try loadOrEmpty(allocator, "this-file-should-not-exist.json");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.value.machines.len);
}

test "find machine by name" {
    const allocator = std.testing.allocator;
    const contents =
        \\{
        \\  "machines": [
        \\    {
        \\      "name": "cpu",
        \\      "provider": "fly",
        \\      "id": "machine-1",
        \\      "host": "devbox.fly.dev",
        \\      "ssh_user": "rove",
        \\      "status": "ready"
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try std.json.parseFromSlice(model.StateFile, allocator, contents, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const machine = findMachine(&parsed.value, "cpu").?;
    try std.testing.expectEqualStrings("machine-1", machine.id);
}

test "upsert and remove machine in saved state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const state_path = try std.fs.path.join(allocator, &.{ tmp_path, "state.json" });
    defer allocator.free(state_path);

    try upsertMachine(allocator, .{
        .name = "cpu",
        .provider = .fly,
        .id = "machine-1",
        .app = "devbox",
        .host = "devbox.fly.dev",
        .ssh_user = "rove",
        .status = .provisioned,
    }, state_path);

    var loaded = try loadOrEmpty(allocator, state_path);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.value.machines.len);
    try std.testing.expectEqualStrings("machine-1", loaded.value.machines[0].id);

    const removed = try removeMachine(allocator, "cpu", state_path);
    try std.testing.expect(removed);

    var empty = try loadOrEmpty(allocator, state_path);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.machines.len);
}
