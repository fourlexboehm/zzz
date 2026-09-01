pub const Handshake = @This();

// TODO(bernardassan):
// Implement suggested client rate limiting on [Page 15]
// https://datatracker.ietf.org/doc/html/rfc6455#section-4.1

pub fn acceptKey(
    gpa: mem.Allocator,
    client_key: []const u8,
) [Base64.calcSize(Sha1.digest_length)]u8 {
    const @"Sec-WebSocket-Key" = mem.trim(
        u8,
        client_key,
        " ",
    );
    const concat = mem.concat(gpa, u8, &.{
        @"Sec-WebSocket-Key",
        guid,
    }) catch @panic("OoM");
    defer gpa.free(concat);

    var sha1: Sha1 = .init(.{});
    sha1.update(concat);
    var final: [Sha1.digest_length]u8 = undefined;
    sha1.final(&final);

    var handshake_accept_key: [Base64.calcSize(final.len)]u8 = undefined;
    _ = Base64.encode(
        &handshake_accept_key,
        final[0..],
    );
    return handshake_accept_key;
}

test acceptKey {
    const gpa = testing.allocator;
    const actual = acceptKey(gpa, "dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings(
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
        actual[0..],
    );
}

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Sha1 = std.crypto.hash.Sha1;
const Base64 = std.base64.standard.Encoder;
