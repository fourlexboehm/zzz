/// Internally exposed secsock.
pub const Secsock = @import("secsock");

/// Internally exposed Tardy.
pub const tardy = @import("tardy");

pub const core = @import("core.zig");

/// HyperText Transfer Protocol.
/// Supports: HTTP/1.1
pub const http = @import("http.zig");

/// WebSocket Protocal
pub const websocket = @import("websocket.zig");

/// These are various general configuration
/// options that are important for the actual framework.
///
/// This includes various different options and limits
/// for interacting with the underlying network.
pub const Config = struct {
    /// Stack Size
    ///
    /// If you have a large number of middlewares or
    /// create a LOT of stack memory, you may want to increase this.
    ///
    /// P.S: A lot of functions in the standard library do end up allocating
    /// a lot on the stack (such as std.log).
    ///
    /// Default: 1MB
    stack_size: tardy.Coroutine.Stack = .@"1MiB",
    /// Use a Max Header Size of 8KiB same as Nginx, Tomcat and Httpd but
    /// consider making this configurable
    /// https://stackoverflow.com/questions/686217/maximum-on-http-header-values
    /// Default: 8KiB
    max_http_header_size: core.Size = .@"8KiB",
    /// Maximum number of header fields in a Request/Response
    /// https://datatracker.ietf.org/doc/html/rfc9110#name-field-limits
    ///
    /// Default: 32
    max_header_fields_count: u32 = 32,
    /// Maximum size (in bytes) of the Request.
    ///
    /// Default: 2MiB
    max_request_size: core.Size = .@"2MiB",
    /// Maximum size (in bytes) of the Request URI.
    ///
    /// Default: 2KiB
    max_request_uri_size: core.Size = .@"2KiB",
    /// Number of Maximum Concurrent Connections.
    ///
    /// This is applied PER runtime.
    /// zzz will drop/close any connections greater
    /// than this.
    ///
    /// You can set this to `null` to have no maximum.
    ///
    /// Default: `null`
    max_connection_count: ?u32 = null,
    /// Maximum number of Captures in a Route
    ///
    /// Default: 8
    max_capture_count: u16 = 8,
    /// Number of times a Request-Response can happen with keep-alive.
    ///
    /// Setting this to `null` will set no limit.
    ///
    /// Default: `null`
    max_keepalive_count: ?u16 = null,
    /// Amount of allocated memory retained
    /// after an arena is cleared.
    ///
    /// A higher value will increase memory usage but
    /// should make allocators faster.
    ///
    /// A lower value will reduce memory usage but
    /// will make allocators slower.
    ///
    /// Default: 1MiB
    retained_arena_bytes: core.Size = .@"1MiB",
    /// Amount of space on the `recv_buffer` retained
    /// after every send.
    ///
    /// Default: 1MiB
    retained_recv_bytes: core.Size = .@"1MiB",
    /// Maximum size (in bytes) of the Recv buffer.
    /// This is mainly a concern when you are reading in
    /// large requests before responding.
    ///
    /// Default: 2MiB
    max_recv_buffer_size: core.Size = .@"2MiB",
    /// Size of the buffer (in bytes) used for
    /// interacting with the socket.
    ///
    /// Default: 1 MiB
    socket_buffer_size: core.Size = .@"1MiB",
};
