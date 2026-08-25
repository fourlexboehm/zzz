pub const Headers = @This();

map: Store,

pub const empty: Headers = .{
    .map = .empty,
};

pub fn parse(
    header: *Headers,
    gpa: mem.Allocator,
    request: []const u8,
    options: Options,
) (OoM || http.Error)!void {
    header.map.clearRetainingCapacity();

    var lines = mem.tokenizeAny(
        u8,
        request,
        "\r\n",
    );

    if (lines.peek() == null) return error.MalformedRequest;

    const request_line = lines.next().?;

    var chunks = mem.tokenizeScalar(
        u8,
        request_line,
        ' ',
    );

    const method_string = chunks.next() orelse
        return error.MalformedRequest;

    const method: http.Method = try .parse(method_string);

    const uri_string = chunks.next() orelse
        return error.MalformedRequest;

    if (uri_string.len >= options.max_uri_bytes.Usize())
        return error.URITooLong;

    if (uri_string[0] != '/') return error.MalformedRequest;

    const version_string = chunks.next() orelse
        return error.MalformedRequest;

    if (!mem.eql(u8, version_string, "HTTP/1.1"))
        return error.UnSupportedHTTPVersion;

    header.set(
        .{ .method = method, .uri = uri_string },
    );

    // There shouldn't be anything else.
    if (chunks.next() != null) return error.MalformedRequest;

    var total_size: usize = 0;
    while (lines.next()) |line| : ({
        total_size += line.len;
    }) {
        if (total_size > options.max_request_bytes.Usize())
            return error.ContentTooLarge;

        var header_iter = mem.tokenizeScalar(
            u8,
            line,
            ':',
        );
        const key = header_iter.next() orelse
            return error.MalformedRequest;

        const value = mem.trimStart(
            u8,
            header_iter.rest(),
            " ",
        );

        if (value.len == 0) return error.MalformedRequest;

        try header.headers.put(gpa, key, value);
    }

    if (header.headers.get("Cookie")) |cookies|
        try header.cookies.parse(gpa, cookies);
}

test "http.Headers: Add Stuff" {
    const gpa = testing.allocator;
    var header: Store = .empty;
    defer header.deinit(gpa);

    try header.put(gpa, "Content-Length", "100");
    try header.put(gpa, "Host", "localhost:9999");

    const content_length = header.get("Content-length");
    try testing.expect(content_length != null);

    const host = header.get("host");
    try testing.expect(host != null);
}

const Options = struct {
    max_request_bytes: core.Size,
    max_uri_bytes: core.Size,
};

const Store = std.HashMapUnmanaged(
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

const std = @import("std");
const mem = std.mem;
const OoM = mem.Allocator.Error;
const array_hash_map = std.array_hash_map;
const ascii = std.ascii;
const testing = std.testing;

const zzz = @import("zzz");
const core = zzz.core;
const http = zzz.http;
