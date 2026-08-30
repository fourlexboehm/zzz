pub const Server = @This();

config: zzz.Config,

pub fn init(config: zzz.Config) Server {
    return .{ .config = config };
}

pub fn deinit(_: *const Server) void {}

/// Serve an HTTP server.
pub fn serve(
    server: *const Server,
    rt: *Runtime,
    router: *const Router,
    tls: *const Secsock,
) !void {
    const tls_info = tls.info();
    log.info("security mode: {t}", .{tls_info.name});

    const count = server.config.max_connection_count orelse 1024;
    const pooling: pool.Kind = if (server.config.max_connection_count == null)
        .grow
    else
        .static;

    const provision_pool = try rt.gpa.create(
        pool.Pool(Provision),
    );
    provision_pool.* = try .init(rt.gpa, count, pooling);
    errdefer rt.gpa.destroy(provision_pool);

    const connection_count = try rt.gpa.create(usize);
    errdefer rt.gpa.destroy(connection_count);
    connection_count.* = 0;

    const accept_queued = try rt.gpa.create(bool);
    errdefer rt.gpa.destroy(accept_queued);
    accept_queued.* = true;

    // initialize first batch of provisions :)
    for (provision_pool.items) |*provision| {
        provision.initalized = true;
        provision.queries = .empty;
        provision.storage = .empty;
        provision.request = .empty;
        provision.response = .empty;

        provision.zc_recv_buffer = try .init(
            rt.gpa,
            server.config.socket_buffer_size.Usize(),
        );
        errdefer provision.zc_recv_buffer.deinit(rt.gpa);

        const header_buf = try rt.gpa.alloc(
            u8,
            server.config.max_http_header_size.Usize(),
        );
        errdefer rt.gpa.free(header_buf);
        provision.header_writer = .fixed(header_buf);

        provision.captures = try rt.gpa.alloc(
            Trie.Capture,
            server.config.max_capture_count,
        );
        errdefer rt.gpa.free(provision.captures);

        provision.arena = .init(rt.gpa);

        try provision.request.headers.ensureTotalCapacity(
            rt.gpa,
            server.config.max_header_fields_count,
        );
        try provision.response.headers.ensureTotalCapacity(
            rt.gpa,
            server.config.max_header_fields_count,
        );
    }

    try rt.spawn(
        mainLoop,
        .{
            rt,
            server.config,
            router,
            tls,
            provision_pool,
            connection_count,
            accept_queued,
        },
        server.config.stack_size,
    );
}

pub fn mainLoop(
    rt: *Runtime,
    config: zzz.Config,
    router: *const Router,
    tls: *const Secsock,
    provisions: *pool.Pool(Provision),
    connection_count: *usize,
    accept_queued: *bool,
) !void {
    accept_queued.* = false;
    var secure = tls.accept(rt) catch |e| {
        if (!accept_queued.*) {
            try rt.spawn(
                mainLoop,
                .{
                    rt,
                    config,
                    router,
                    tls,
                    provisions,
                    connection_count,
                    accept_queued,
                },
                config.stack_size,
            );
            accept_queued.* = true;
        }
        return e;
    };
    defer secure.deinit(rt.gpa);
    const secure_info = secure.info();

    connection_count.* += 1;
    defer connection_count.* -= 1;

    if (config.max_connection_count) |max| if (connection_count.* > max) {
        return log.debug("over connection max, closing", .{});
    };

    log.debug("queuing up a new accept request", .{});
    try rt.spawn(
        mainLoop,
        .{
            rt,
            config,
            router,
            tls,
            provisions,
            connection_count,
            accept_queued,
        },
        config.stack_size,
    );
    accept_queued.* = true;

    const index = try provisions.borrow(rt.gpa);
    defer provisions.release(index);
    const provision = provisions.get_ptr(index);

    // if we are growing, we can handle a newly allocated provision here.
    // otherwise, it should be initalized.
    if (!provision.initalized) {
        log.debug("initalizing new provision", .{});

        provision.initalized = true;
        provision.queries = .empty;
        provision.storage = .empty;
        provision.request = .empty;
        provision.response = .empty;

        provision.zc_recv_buffer = try .init(
            rt.gpa,
            config.socket_buffer_size.Usize(),
        );
        errdefer provision.zc_recv_buffer.deinit(rt.gpa);

        const header_buf = try rt.gpa.alloc(
            u8,
            config.max_http_header_size.Usize(),
        );
        errdefer rt.gpa.free(header_buf);
        provision.header_writer = .fixed(header_buf);

        provision.captures = try rt.gpa.alloc(
            Trie.Capture,
            config.max_capture_count,
        );
        errdefer rt.gpa.free(provision.captures);

        provision.arena = .init(rt.gpa);

        try provision.request.headers.ensureTotalCapacity(
            rt.gpa,
            config.max_header_fields_count,
        );
        try provision.response.headers.ensureTotalCapacity(
            rt.gpa,
            config.max_header_fields_count,
        );
    }
    defer prepare_new_request(
        rt.gpa,
        null,
        provision,
        config,
    ) catch unreachable;

    provision.recv_slice = try provision.zc_recv_buffer.get_write_area(
        rt.gpa,
        config.socket_buffer_size.Usize(),
    );

    var keepalive_count: u16 = 0;
    var state: State = .{ .request = .header };

    http_loop: switch (state) {
        .request => |*kind| switch (kind.*) {
            .header => {
                const recv_count = secure.recv(
                    rt,
                    provision.recv_slice,
                ) catch |e|
                    switch (e) {
                        error.Closed => break :http_loop,
                        else => |err| {
                            log.debug(
                                "request=>header recv failed on socket | {t}",
                                .{err},
                            );
                            break :http_loop;
                        },
                    };

                provision.zc_recv_buffer.mark_written(recv_count);
                provision.recv_slice = try provision.zc_recv_buffer.get_write_area(
                    rt.gpa,
                    config.socket_buffer_size.Usize(),
                );
                if (provision.zc_recv_buffer.len > config.max_request_size.Usize())
                    break :http_loop;

                const end_marker = "\r\n\r\n";
                const search_area_start =
                    (provision.zc_recv_buffer.len - recv_count) -| end_marker.len;

                const header_end = mem.find(
                    u8,
                    // Minimize the search area.
                    provision.zc_recv_buffer.subslice(.{
                        .start = search_area_start,
                    }),
                    end_marker,
                ) orelse return error.BadHeader;

                std.debug.print("Raw\n{s}\n", .{
                    provision.zc_recv_buffer.subslice(.{
                        .start = search_area_start,
                    }),
                });
                const real_header_end = header_end + end_marker.len;

                try provision.request.parse(
                    rt.gpa,
                    provision.zc_recv_buffer.subslice(
                        .{ .end = real_header_end },
                    ),
                    .{
                        .max_request_bytes = config.max_request_size,
                        .max_uri_bytes = config.max_request_uri_size,
                    },
                );

                log.info("rt{d} - \"{t} {s}\" {s} ({s})", .{
                    rt.id,
                    provision.request.method.?,
                    provision.request.uri.?,
                    provision.request.headers.get("User-Agent") orelse "N/A",
                    secure_info.address,
                });

                const content_length_str = provision.request.headers.get(
                    "Content-Length",
                ) orelse "0";
                const content_length = try std.fmt.parseUnsigned(
                    usize,
                    content_length_str,
                    10,
                );
                log.debug("content length={d}", .{content_length});

                if (provision.request.expect_body() and content_length != 0) {
                    state = .{
                        .request = .{
                            .body = .{
                                .current_length = provision.zc_recv_buffer.len - real_header_end,
                                .content_length = content_length,
                            },
                        },
                    };
                } else state = .handler;
            },
            .body => |*info| {
                if (info.current_length == info.content_length) {
                    provision.request.body = provision.zc_recv_buffer.subslice(
                        .{
                            .start = provision.zc_recv_buffer.len - info.content_length,
                        },
                    );
                    state = .handler;
                    continue :http_loop state;
                }

                const recv_count = secure.recv(
                    rt,
                    provision.recv_slice,
                ) catch |e|
                    switch (e) {
                        error.Closed => break :http_loop,
                        else => |err| {
                            log.debug(
                                "recv failed on socket | {t}",
                                .{err},
                            );
                            break :http_loop;
                        },
                    };

                provision.zc_recv_buffer.mark_written(recv_count);
                provision.recv_slice = try provision.zc_recv_buffer.get_write_area(
                    rt.gpa,
                    config.socket_buffer_size.Usize(),
                );
                if (provision.zc_recv_buffer.len > config.max_request_size.Usize())
                    break :http_loop;

                info.current_length += recv_count;
                debug.assert(info.current_length <= info.content_length);
            },
        },
        .handler => {
            const found = try router.get_bundle_from_host(
                rt.gpa,
                provision.request.uri.?,
                provision.captures,
                &provision.queries,
            );
            defer rt.gpa.free(found.duped);
            defer for (found.duped) |dupe| rt.gpa.free(dupe);

            const h_with_data: Route.Handler.WithData = found.route.get_handler(
                provision.request.method.?,
            ) orelse {
                provision.response.headers.clearRetainingCapacity();
                provision.response.status = .@"Method Not Allowed";
                provision.response.mime = .TEXT;
                provision.response.body = null;

                state = .respond;
                continue :http_loop state;
            };

            const ctx: http.Context = .{
                .runtime = rt,
                .arena = provision.arena.allocator(),
                .header_writer = &provision.header_writer,
                .request = &provision.request,
                .response = &provision.response,
                .storage = &provision.storage,
                .tls = &secure,
                .captures = found.captures,
                .queries = found.queries,
            };

            var next: Middleware.Next = .{
                .ctx = &ctx,
                .middlewares = h_with_data.middlewares,
                .handler = h_with_data,
            };

            const next_respond: http.Respond = next.run() catch |err| respond: {
                log.warn("rt{d} - \"{t} {s}\" {t} ({s})", .{
                    rt.id,
                    provision.request.method.?,
                    provision.request.uri.?,
                    err,
                    secure_info.address,
                });

                // If in Debug Mode, we will return the error name. In other modes,
                // we won't to avoid leaking implemenation details.
                const body = if (comptime builtin.mode == .debug)
                    @errorName(err)
                else
                    "";

                break :respond try provision.response.apply(.{
                    .status = .@"Internal Server Error",
                    .mime = .TEXT,
                    .body = body,
                });
            };

            switch (next_respond) {
                .standard => {
                    // applies the respond onto the response
                    // try provision.response.apply(respond);
                    state = .respond;
                },
                .responded => {
                    const connection = provision.request.headers.get(
                        "Connection",
                    ) orelse "keep-alive";
                    if (mem.eql(u8, connection, "close")) break :http_loop;
                    if (config.max_keepalive_count) |max| {
                        if (keepalive_count > max) {
                            log.debug(
                                "closing connection, exceeded keepalive max",
                                .{},
                            );
                            break :http_loop;
                        }

                        keepalive_count += 1;
                    }

                    try prepare_new_request(
                        rt.gpa,
                        &state,
                        provision,
                        config,
                    );
                },
                .close => break :http_loop,
            }
        },
        .respond => {
            // TODO: lets use optional properly
            const body = provision.response.body orelse "";
            const content_length = body.len;

            try provision.response.writeHeaders(
                &provision.header_writer,
                content_length,
            );
            const headers = provision.header_writer.buffered();

            var sent: usize = 0;
            const pseudo: zcore.Pseudoslice = .init(
                headers,
                body,
                provision.recv_slice,
            );

            while (sent < pseudo.len) {
                const send_slice = pseudo.get(
                    sent,
                    sent + provision.recv_slice.len,
                );

                const sent_length = secure.send_all(
                    rt,
                    send_slice,
                ) catch |err| {
                    log.debug("send failed on socket | {t}", .{err});
                    break :http_loop;
                };
                if (sent_length != send_slice.len) break :http_loop;
                sent += sent_length;
            }

            const connection = provision.request.headers.get(
                "Connection",
            ) orelse "keep-alive";
            if (mem.eql(u8, connection, "close")) break :http_loop;
            if (config.max_keepalive_count) |max| {
                if (keepalive_count > max) {
                    log.debug(
                        "closing connection, exceeded keepalive max",
                        .{},
                    );
                    break :http_loop;
                }

                keepalive_count += 1;
            }

            try prepare_new_request(
                rt.gpa,
                &state,
                provision,
                config,
            );
        },
    }

    log.info("connection ({s}) closed", .{secure_info.address});

    if (!accept_queued.*) {
        try rt.spawn(
            mainLoop,
            .{
                rt,
                config,
                router,
                tls,
                provisions,
                connection_count,
                accept_queued,
            },
            config.stack_size,
        );
        accept_queued.* = true;
    }
}

fn prepare_new_request(
    gpa: mem.Allocator,
    state: ?*State,
    provision: *Provision,
    config: zzz.Config,
) !void {
    debug.assert(provision.initalized);
    provision.request.clear(gpa);
    provision.response.clear();
    provision.storage.clear(gpa);
    provision.zc_recv_buffer.clear_retaining_capacity();
    _ = provision.header_writer.consumeAll();
    _ = provision.arena.reset(.{
        .retain_with_limit = config.retained_arena_bytes.Usize(),
    });
    provision.recv_slice = try provision.zc_recv_buffer.get_write_area(
        gpa,
        config.socket_buffer_size.Usize(),
    );

    if (state) |s| s.* = .{ .request = .header };
}

const Request = union(enum) {
    header,
    body: Body,

    const Body = struct {
        content_length: usize,
        current_length: usize,
    };
};

const State = union(enum) {
    request: Request,
    handler,
    respond,
};

pub const Provision = struct {
    // TODO: store this bool out of band
    initalized: bool = false,
    recv_slice: []u8,
    zc_recv_buffer: ZeroCopy(u8),
    header_writer: Io.Writer,
    arena: heap.ArenaAllocator,
    storage: zcore.Storage,
    captures: []Trie.Capture,
    queries: http.Queries,
    request: http.Request,
    response: http.Response,
};

const log = std.log.scoped(.@"zzz/http/Server");

const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const debug = std.debug;
const Io = std.Io;
const builtin = @import("builtin");

const zzz = @import("zzz");
const zcore = zzz.core;
const tardy = zzz.tardy;
const Coroutine = tardy.Coroutine;
const tcore = tardy.core;
const ZeroCopy = tcore.ZeroCopy;
const pool = tcore.pool;
const Runtime = tardy.Runtime;
const Secsock = zzz.Secsock;
const Socket = tardy.net.Socket;
const Task = Runtime.Task;
const http = zzz.http;
const Router = http.Router;
const Route = Router.Route;
const Middleware = Router.Middleware;
const Trie = Router.Trie;
