test "zzz unit tests" {
    // Core
    _ = core.Pseudoslice;
    _ = core.Storage;

    // HTTP
    _ = http.Context;
    _ = http.Date;
    _ = http.Method;
    _ = http.Mime;
    _ = http.Request;
    _ = http.Response;
    _ = http.Server;
    _ = http.SSE;
    _ = http.Status;
    _ = http.form;
    _ = http.Headers;

    // Router
    _ = http.Router;
    _ = http.Router.Route;
    _ = http.Router.Trie;
}

const zzz = @import("zzz");
const core = zzz.core;
const http = zzz.http;

test "drain after keep-alive headers cannot silently change connection policy" {
    const std = @import("std");
    var stopping: std.atomic.Value(bool) = .init(false);
    var response: http.Response = .empty;
    response.status = .OK;
    response.mime = .TEXT;
    response.close_signal = &stopping;
    var bytes: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try response.headers_into_writer(&writer, 0);
    stopping.store(true, .release);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Connection: keep-alive") != null);
    try std.testing.expect(!response.connection_close);
    response.clear();
    response.status = .OK;
    response.mime = .TEXT;
    writer = .fixed(&bytes);
    try response.headers_into_writer(&writer, 0);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Connection: close") != null);
    try std.testing.expect(response.connection_close);
}

test "drain failure is reported by completion waiter" {
    const std = @import("std");
    // No listener is touched: failure must be surfaced before waiting on I/O.
    var drain: http.Server.Drain = .{ .listener = undefined };
    drain.drain_failed.store(true, .release);
    try std.testing.expect(!drain.isDrained());
    try std.testing.expectError(error.DrainFailed, drain.waitDrainedBlocking(std.testing.io, null));
}

test "controlled server cancels pending accept and drains" {
    const std = @import("std");
    const mem = std.mem;
    const testing = std.testing;
    const tardy = zzz.tardy;
    const Server = http.Server;
    const Drain = Server.Drain;
    const Secsock = zzz.Secsock;
    const Socket = tardy.net.Socket;
    const Router = http.Router;
    const Runtime = tardy.Runtime;
    const gpa = std.heap.page_allocator;
    const port = 38621;
    const transport: Secsock.Unsecured = .empty;
    const listener = try transport.tcp(gpa, .{
        .host = "127.0.0.1",
        .port = port,
    });
    defer listener.deinit(gpa);

    var router: Router = try .init(gpa, &.{}, .{});
    defer router.deinit(gpa);

    var drain: Drain = .init(&listener);
    var completed = false;

    const Params = struct {
        router: *const Router,
        listener: *const Secsock,
        drain: *Drain,
        completed: *bool,
        port: u16,
    };
    const params: Params = .{
        .router = &router,
        .listener = &listener,
        .drain = &drain,
        .completed = &completed,
        .port = port,
    };

    const Tardy = tardy.Tardy(.auto);
    var td: Tardy = try .init(gpa, testing.io, .{
        .threading = .{ .multi = 2 },
    });
    defer td.deinit();

    try td.entry(params, struct {
        fn entry(rt: *Runtime, p: Params) !void {
            const server: Server = .init(.{
                .stack_size = .@"64KiB",
                .socket_buffer_size = .@"2KiB",
            });
            try server.serveWithDrain(
                rt,
                p.router,
                p.listener,
                p.drain,
            );
            if (rt.id == 0) {
                try rt.spawn(
                    exerciseConnection,
                    .{ rt, p.drain, p.completed, p.port },
                    .@"64KiB",
                );
            }
        }

        fn exerciseConnection(
            rt: *Runtime,
            control: *Drain,
            done: *bool,
            port_number: u16,
        ) !void {
            var client: Socket = try .init(.{
                .tcp = .{
                    .host = "127.0.0.1",
                    .port = port_number,
                    .mode = .client,
                },
            });
            defer client.close_blocking();
            try client.connect(rt);

            const request =
                "GET / HTTP/1.1\r\nHost: localhost\r\n" ++
                "Connection: keep-alive\r\n\r\n";
            try testing.expectEqual(
                request.len,
                try client.send_all(rt, request),
            );

            var response: [1024]u8 = undefined;
            const response_len = try client.recv(rt, &response);
            try testing.expect(mem.containsAtLeast(
                u8,
                response[0..response_len],
                1,
                "Connection: keep-alive",
            ));

            while (!control.isReady())
                try Runtime.Timer.delay(rt, .fromMilliseconds(1));
            try Runtime.Timer.delay(rt, .fromMilliseconds(20));
            control.beginDrain();
            try testing.expect(!control.isDrained());
            try testing.expectEqual(request.len, try client.send_all(rt, request));
            const closing_len = try client.recv(rt, &response);
            try testing.expect(mem.containsAtLeast(u8, response[0..closing_len], 1, "Connection: close"));
            try control.waitDrained(rt, .fromSeconds(2));
            done.* = true;
        }
    }.entry);

    try testing.expect(completed);
    try testing.expect(drain.isDrained());
}
