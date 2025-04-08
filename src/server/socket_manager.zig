const std = @import("std");

const log = std.log;
const math = std.math;
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const ArrayList = std.ArrayList;

const Socket = @import("./socket.zig");

const Self = @This();

var shared_message_buffer: [1024]u8 = undefined;
var last_message = Socket.IncomingMessage{
    .buffer = &shared_message_buffer
};

allocator: mem.Allocator,
sockets: ArrayList(Socket),

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
        .sockets = ArrayList(Socket).init(allocator)
    };
}

pub const ListenError = posix.SocketError || posix.BindError || posix.GetSockNameError || mem.Allocator.Error || error{InvalidAddress};

/// Binds a new socket on the specified address / port.
pub fn listen(self: *Self, address: []const u8, port: u16) ListenError!void {
    var socket = switch (address.len) {
        4 => try initSocketForIPv4Address(address, port),
        16 => try initSocketForIPv6Address(address, port),
        else => return error.InvalidAddress
    };

    errdefer socket.close();
    try socket.listen();
    try self.sockets.append(socket);
}

/// Waits for a new message to be received and loads it into `out_message`.
/// Cancels the process if the cancellation token is set.
pub fn waitForMessage(self: *Self, out_message: *IncomingMessage, cancellation_token: *const bool) (posix.RecvFromError || mem.Allocator.Error || posix.PollError || error{MessageBufferTooLarge})!?usize {
    var pollfd_list = ArrayList(posix.pollfd).init(self.allocator);
    defer pollfd_list.deinit();

    try self.getPollFileDescriptorsForBoundSockets(&pollfd_list);
    if (pollfd_list.items.len == 0) return null;

    while (!cancellation_token.*) {
        const poll_result = try posix.poll(pollfd_list.items, 5_000);
        if (poll_result == 0) continue;

        for (pollfd_list.items) | pollfd | {
            if (pollfd.revents == 0) continue;
            return try receiveNextMessage(pollfd, out_message);
        }
    }

    return null;
}

/// Frees the resources used by the socket manager including all sockets it holds
pub fn deinit(self: *Self) void {
    for (0..self.sockets.items.len) | index | self.sockets.items[index].close();
    self.sockets.deinit();
}

/// Receives the next message.
/// Returns NULL if there is no message or the socket is not listening.
fn receiveNextMessage(pollfd: posix.pollfd, out_message: *IncomingMessage)  (posix.RecvFromError || posix.PollError || error{MessageBufferTooLarge})!?usize {
    if (out_message.buffer.len > MAX_MESSAGE_BUFFER_LENGTH) return error.MessageBufferTooLarge;

    @memset(out_message.buffer, 0);
    @memset(&out_message.source_address.any.data, 0);

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
fn initSocketForIPv4Address(address: []const u8, port: u16) error { InvalidAddress }!Socket {
    if (address.len != 4) return error.InvalidAddress;
    var fs_address: [4]u8 = undefined;
    @memcpy(&fs_address, address);
    return Socket.initIPv4(fs_address, port);
}

/// Initializes a socket on an IPv6 address
fn initSocketForIPv6Address(address: []const u8, port: u16) error { InvalidAddress }!Socket {
    if (address.len != 16) return error.InvalidAddress;
    var fs_address: [16]u8 = undefined;
    @memcpy(&fs_address, address);
    return Socket.initIPv6(fs_address, port);
}