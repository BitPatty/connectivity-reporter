const std = @import("std");

const log = std.log;
const mem = std.mem;
const net = std.net;
const time = std.time;
const thread = std.Thread;

const config = @import("../config.zig");
const SocketManager = @import("./socket_manager.zig");

/// Starts the server with the specified socket configurations.
/// If no configurations are available the server won't be started and idle.
/// The server will continue running for as long as the cancellation token is not set.
pub fn startServer(allocator: mem.Allocator, socket_configurations: []config.SocketConfiguration, cancellation_token: *const bool) void {
    if(socket_configurations.len == 0) {
        log.warn("No configurations configured, server idling", .{});
        while (!cancellation_token.*) thread.sleep(time.ns_per_s);
    }

    var manager = SocketManager.init(allocator);
    defer manager.deinit();

    var message_buffer: [1024]u8 = undefined;
    var source_address: net.Address = undefined;
    var last_message = SocketManager.IncomingMessage{
        .buffer = &message_buffer,
        .source_address = &source_address
    };

    for (socket_configurations) | socket_configuration | {
        log.debug("Found config: {d}:{d}", .{ socket_configuration.bind_address, socket_configuration.bind_port });
        manager.listen(socket_configuration.bind_address, socket_configuration.bind_port, socket_configuration.protocol) catch | err | {
            log.debug("Failed to add address: {}", .{ err });
        };
    }

    while (!cancellation_token.*) {
        if (manager.waitForMessage(&last_message, cancellation_token)) | message_size | {
            if (message_size != null) log.debug("Received message {s} from {}", .{ last_message.buffer, last_message.source_address});
        } else |err| {
            log.debug("Failed to process message {}", .{ err });
        }
    }
}


