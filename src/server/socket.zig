const std = @import("std");

const log = std.log;
const math = std.math;
const net = std.net;
const posix = std.posix;

const AddressFamily = @import("../enums.zig").AddressFamily;

const Self = @This();

address_family: AddressFamily,
listen_address: net.Address,
posix_socket: ?posix.socket_t,

pub const SocketError = posix.SocketError || posix.BindError || posix.GetSockNameError;

/// Initializes a new socket for the specified IPv6 address / port pair
pub fn initIPv6(address: [16]u8, port: u16) Self {
    return .{
        .address_family = .IPv6,
        .listen_address = net.Address.initIp6(address, port, 0, 0),
        .posix_socket = null
    };
}

/// Initializes a new socket for the specified IPv4 address / port pair
pub fn initIPv4(address: [4]u8, port: u16) Self {
    return .{
        .address_family = .IPv4,
        .listen_address = net.Address.initIp4(address, port),
        .posix_socket = null
    };
}

/// Starts listening on the socket.
/// `close` needs to be called after processing has been completed to free the binding.
/// Binding will fail if the address is invalid or no interface is bound to the address.
pub fn listen(self: *Self) SocketError!void {
    const sockfd = posix.socket(self.listen_address.any.family, posix.SOCK.DGRAM, posix.IPPROTO.UDP) catch |err| {
        log.err("Could not initialize socket: {}", .{ err });
        return err;
    };

    var socklen = self.listen_address.getOsSockLen();
    posix.bind(sockfd, &self.listen_address.any, socklen) catch |err| {
        log.err("Could not bind address: {}", .{ err });
        return err;
    };
    errdefer self.close();

    var in_addr: net.Address = undefined;
    posix.getsockname(sockfd, &in_addr.any, &socklen) catch |err| {
        log.err("Could get socket name: {}", .{ err });
        return err;
    };

    log.info("Listening on {}", .{ in_addr });
    self.posix_socket = sockfd;
}

/// Closes the socket
pub fn close(self: *Self) void {
    if (self.posix_socket == null) return;
    posix.close(self.posix_socket.?);
    self.posix_socket = null;
}
