const std = @import("std");

pub fn quote(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeByte('\'');
    for (raw) |char| {
        if (char == '\'') {
            try out.writer.writeAll("'\"'\"'");
        } else {
            try out.writer.writeByte(char);
        }
    }
    try out.writer.writeByte('\'');

    return allocator.dupe(u8, out.written());
}

test "quote escapes single quotes" {
    const allocator = std.testing.allocator;
    const quoted = try quote(allocator, "a'b");
    defer allocator.free(quoted);

    try std.testing.expectEqualStrings("'a'\"'\"'b'", quoted);
}
