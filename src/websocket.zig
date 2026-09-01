//! The WebSocket Protocol enables two-way communication between a client
//! running untrusted code in a controlled environment to a remote host
//! that has opted-in to communications from that code.
pub const Server = @import("websocket/Server.zig");
pub const handshake = @import("websocket/handshake.zig");
