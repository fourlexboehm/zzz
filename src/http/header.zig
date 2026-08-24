pub const Headers = std.HashMapUnmanaged(
    []const u8,
    []const u8,
    // needed because the comparision ignores case
    CaseInsensitive,
    std.hash_map.default_max_load_percentage,
);

// https://datatracker.ietf.org/doc/html/rfc9110#section-5.1
const CaseInsensitive = struct {
    pub fn hash(_: @This(), key: []const u8) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        for (key) |byte| hasher.update(mem.asBytes(&ascii.toLower(byte)));
        return hasher.final();
    }

    pub fn eql(_: @This(), key_a: []const u8, key_b: []const u8) bool {
        return ascii.eqlIgnoreCase(key_a, key_b);
    }
};

test "http.Headers: Add Stuff" {
    const gpa = testing.allocator;
    var header: Headers = .empty;
    defer header.deinit(gpa);

    try header.put(gpa, "Content-Length", "100");
    try header.put(gpa, "Host", "localhost:9999");

    const content_length = header.get("Content-length");
    try testing.expect(content_length != null);

    const host = header.get("host");
    try testing.expect(host != null);
}

const std = @import("std");
const mem = std.mem;
const array_hash_map = std.array_hash_map;
const ascii = std.ascii;
const testing = std.testing;
