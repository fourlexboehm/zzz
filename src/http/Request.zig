pub const Request = @This();

version: http.Version = .@"HTTP/1.1",
method: ?http.Method = null,
uri: ?[]const u8 = null,
headers: http.Headers,
cookies: Cookie.Map,
body: ?[]const u8 = null,

/// This is for constructing a Request.
pub const empty: Request = .{
    .headers = .empty,
    .cookies = .empty,
};

pub fn deinit(request: *Request, gpa: mem.Allocator) void {
    request.cookies.deinit(gpa);
    request.headers.deinit(gpa);
}

pub fn clear(request: *Request, gpa: mem.Allocator) void {
    request.method = null;
    request.uri = null;
    request.body = null;
    request.cookies.clear(gpa);
    request.headers.clearRetainingCapacity();
}

pub fn parse(
    request: *Request,
    gpa: mem.Allocator,
    header: []const u8,
    options: Options,
) (OoM || http.Error)!void {
    request.headers.clearRetainingCapacity();

    var lines = mem.tokenizeAny(
        u8,
        header,
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
    request.method = method;

    const uri = chunks.next() orelse
        return error.MalformedRequest;

    if (uri.len >= options.max_uri_bytes.Usize())
        return error.URITooLong;

    if (uri[0] != '/') return error.MalformedRequest;
    request.uri = uri;

    const version_string = chunks.next() orelse
        return error.MalformedRequest;

    const version = meta.stringToEnum(
        http.Version,
        version_string,
    ) orelse return error.UnSupportedHTTPVersion;
    request.version = version;

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

        try request.headers.put(gpa, key, value);
    }

    if (request.headers.get("Cookie")) |cookies|
        try request.cookies.parse(gpa, cookies);
}

/// Should this specific Request expect to capture a body.
pub fn expect_body(request: *const Request) bool {
    return switch (request.method orelse return false) {
        .POST, .PUT, .PATCH => true,
        .GET, .HEAD, .DELETE, .CONNECT, .OPTIONS, .TRACE => false,
    };
}

test "Parse Request" {
    const gpa = testing.allocator;
    const request_header =
        \\GET / HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    var request: Request = .empty;
    defer request.deinit(gpa);

    try request.parse(gpa, request_header[0..], .{
        .max_request_bytes = .KiB(1),
        .max_uri_bytes = .Bytes(256),
    });

    try testing.expectEqual(.GET, request.method);
    try testing.expectEqualStrings("/", request.uri.?);
    try testing.expectEqual(.@"HTTP/1.1", request.version);

    try testing.expectEqualStrings(
        "localhost:9862",
        request.headers.get("Host").?,
    );
    try testing.expectEqualStrings(
        "keep-alive",
        request.headers.get("Connection").?,
    );
    try testing.expectEqualStrings(
        "text/html",
        request.headers.get("Accept").?,
    );
}

test "Expect ContentTooLong Error" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const large_content: [4096]u8 = @splat('a');
    const request_text = fmt.comptimePrint(
        request_text_format,
        .{large_content},
    );
    const gpa = testing.allocator;
    var request: Request = .empty;
    defer request.deinit(gpa);

    const err = request.parse(
        gpa,
        request_text[0..],
        .{
            .max_request_bytes = .Bytes(128),
            .max_uri_bytes = .Bytes(64),
        },
    );
    try testing.expectError(
        error.ContentTooLarge,
        err,
    );
}

test "Expect URITooLong Error" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const large_content: [4096]u8 = @splat('a');
    const request_text = fmt.comptimePrint(
        request_text_format,
        .{large_content[0..]},
    );
    const gpa = testing.allocator;
    var request: Request = .empty;
    defer request.deinit(gpa);

    const err = request.parse(
        gpa,
        request_text[0..],
        .{
            .max_request_bytes = .@"1MiB",
            .max_uri_bytes = .@"2KiB",
        },
    );
    try testing.expectError(error.URITooLong, err);
}

test "Expect Malformed when URI missing /" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;
    const content: [256]u8 = @splat('a');
    const request_text = fmt.comptimePrint(
        request_text_format,
        .{content[0..]},
    );
    const gpa = testing.allocator;
    var request: Request = .empty;
    defer request.deinit(gpa);

    const err = request.parse(
        gpa,
        request_text[0..],
        .{
            .max_request_bytes = .KiB(1),
            .max_uri_bytes = .Bytes(512),
        },
    );
    try testing.expectError(
        error.MalformedRequest,
        err,
    );
}

test "Expect Incorrect HTTP Version" {
    const request_text =
        \\GET / HTTP/1.4
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const gpa = testing.allocator;
    var request: Request = .empty;
    defer request.deinit(gpa);

    const err = request.headers.parse(
        gpa,
        request_text[0..],
        .{
            .max_request_bytes = .KiB(1),
            .max_uri_bytes = .Bytes(512),
        },
    );
    try testing.expectError(
        error.UnSupportedHTTPVersion,
        err,
    );
}

test "Malformed Request" {
    const request_text =
        \\GET / HTTP/1.1
        \\Host: localhost:9862
        \\Connection:
        \\Accept: text/html
    ;

    const gpa = testing.allocator;
    var request: Request = .empty;
    defer request.deinit(gpa);

    const err = request.parse(
        gpa,
        request_text[0..],
        .{
            .max_request_bytes = .KiB(1),
            .max_uri_bytes = .Bytes(512),
        },
    );
    try testing.expectError(
        error.MalformedRequest,
        err,
    );
}

const Options = struct {
    max_request_bytes: core.Size,
    max_uri_bytes: core.Size,
};

const log = std.log.scoped(.@"zzz/http/request");

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const meta = std.meta;
const testing = std.testing;
const OoM = mem.Allocator.Error;

const zzz = @import("zzz");
const core = zzz.core;
const http = zzz.http;
const Cookie = @import("Cookie.zig");
