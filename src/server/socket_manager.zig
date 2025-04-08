const std = @import("std");

const log = std.log;
const math = std.math;
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const ArrayList = std.ArrayList;

const Socket = @import("./socket.zig");
const SocketProtocol = @import("../enums.zig").SocketProtocol;

const Self = @This();

var shared_message_buffer: [1024]u8 = undefined;
var last_message = Socket.IncomingMessage{
    .buffer = &shared_message_buffer
};

allocator: mem.Allocator,
sockets: ArrayList(*Socket),

/// The max length for the message buffer
const MAX_MESSAGE_BUFFER_LENGTH: u32 = math.maxInt(u32);

/// A received socket message
pub const IncomingMessage = struct {
    source_address: *net.Address,
    buffer: []u8
};

/// Initializes the socket manager
pub fn init(allocator: mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .sockets = ArrayList(*Socket).init(allocator)
    };
}

/// Binds a new socket on the specified address / port.
pub fn listen(self: *Self, address: []const u8, port: u16, protocol: SocketProtocol) !void {
    var socket = switch (address.len) {
        4 => try initSocketForIPv4Address(address, port, protocol),
        16 => try initSocketForIPv6Address(address, port, protocol),
        else => return error.InvalidAddress
    };
    errdefer socket.close();

    var allocated_socket = try self.allocator.create(Socket);
    allocated_socket.* = socket;

    try self.sockets.append(allocated_socket);
    try allocated_socket.listen();
}


/// Waits for a new message to be received and loads it into `out_message`.
/// Cancels the process if the cancellation token is set.
pub fn waitForMessage(self: *Self, out_message: *IncomingMessage, cancellation_token: *const bool) !?usize {
    var pollfd_list = ArrayList(posix.pollfd).init(self.allocator);
    defer pollfd_list.deinit();

    while (!cancellation_token.*) {
        self.restartDeadSockets();

        try self.getPollFileDescriptorsForBoundSockets(&pollfd_list);
        if (pollfd_list.items.len == 0) return null;

        const poll_result = try posix.poll(pollfd_list.items, 5_000);
        if (poll_result == 0) {
            log.debug("No messages received", .{ });
            continue;
        }

        for (pollfd_list.items) | pollfd | {
            if (pollfd.revents == 0) continue;
            return try self.receiveNextMessageOnSocket(pollfd, out_message);
        }
    }

    return null;
}

/// Frees the resources used by the socket manager including all sockets it holds
pub fn deinit(self: *Self) void {
    for (0..self.sockets.items.len) | index | {
        self.sockets.items[index].close();
        self.allocator.destroy(self.sockets.items[index]);
    }
    self.sockets.deinit();
}

/// Restarts all sockets that are not bound
fn restartDeadSockets(self: *Self) void {
    for (0..self.sockets.items.len) | index | {
        if (self.sockets.items[index].posix_socket != null) continue;

        log.debug("Attempting to start socket {} {}", .{ self.sockets.items[index].protocol, self.sockets.items[index].listen_address });
        self.sockets.items[index].listen() catch | err | {
            log.warn("Failed to start socket: {} {} {}", .{ self.sockets.items[index].protocol, self.sockets.items[index].listen_address, err });
        };
    }
}

/// Gets the socket for the specified file descriptor
fn getSocketByFileDescriptor(self: *Self, pollfd: posix.pollfd) !*Socket {
    for (self.sockets.items) | socket | {
        if (socket.posix_socket == null) continue;
        if (socket.posix_socket.? == pollfd.fd) return socket;
    }

    return error.SocketNotFound;
}

/// Receives the next message.
/// Returns NULL if there is no message or the socket is not listening.
fn receiveNextMessageOnSocket(self: *Self, pollfd: posix.pollfd, out_message: *IncomingMessage)  !?usize {
    var target_socket = try self.getSocketByFileDescriptor(pollfd);
    if (out_message.buffer.len > MAX_MESSAGE_BUFFER_LENGTH) return error.MessageBufferTooLarge;

    @memset(out_message.buffer, 0);
    @memset(&out_message.source_address.any.data, 0);

    // TCP messages
    if (target_socket.server != null) {
        const connection = try target_socket.accept();
        defer connection.stream.close();
        const msg = try connection.stream.readAll(out_message.buffer);
        out_message.source_address.* = connection.address;
        return msg;
    }

    // UDP messages
    var address_length: u32 = out_message.source_address.any.data.len;
    const bytes_read = try posix.recvfrom(pollfd.fd, out_message.buffer, 0, &out_message.source_address.any, &address_length);
    return bytes_read;
}

/// Populates `out` with a list of poll file descriptors for the sockets with an active binding
fn getPollFileDescriptorsForBoundSockets(self: Self, out: *ArrayList(posix.pollfd)) mem.Allocator.Error!void {
    for (self.sockets.items) | socket | {
        if (socket.posix_socket == null) continue;
        const pollfd = getPosixSocketPollFileDescriptor(socket.posix_socket.?);
        try out.append(pollfd);
    }
}

/// Gets a poll file descriptor for a posix socket
fn getPosixSocketPollFileDescriptor(socket: posix.socket_t) posix.pollfd {
    return posix.pollfd{
        .fd = socket,
        .events = posix.POLL.IN,
        .revents = 0,
    };
}

/// Initializes a socket on an IPv4 address
fn initSocketForIPv4Address(address: []const u8, port: u16, protocol: SocketProtocol) error { InvalidAddress }!Socket {
    if (address.len != 4) return error.InvalidAddress;
    var fd_address: [4]u8 = undefined;
    @memcpy(&fd_address, address);
    return Socket.initIPv4(fd_address, port, protocol);
}

/// Initializes a socket on an IPv6 address
fn initSocketForIPv6Address(address: []const u8, port: u16, protocol: SocketProtocol) error { InvalidAddress }!Socket {
    if (address.len != 16) return error.InvalidAddress;
    var fd_address: [16]u8 = undefined;
    @memcpy(&fd_address, address);
    return Socket.initIPv6(fd_address, port, protocol);
}