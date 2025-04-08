const std = @import("std");

const log = std.log;
const math = std.math;
const net = std.net;
const posix = std.posix;

const AddressFamily = @import("../enums.zig").AddressFamily;
const SocketProtocol = @import("../enums.zig").SocketProtocol;

const Self = @This();

protocol: SocketProtocol,
address_family: AddressFamily,
listen_address: net.Address,
posix_socket: ?posix.socket_t,
server: ?net.Server,

/// Initializes a new socket for the specified IPv6 address / port pair
pub fn initIPv6(address: [16]u8, port: u16, protocol: SocketProtocol) Self {
    return .{
        .address_family = .IPv6,
        .listen_address = net.Address.initIp6(address, port, 0, 0),
        .posix_socket = null,
        .protocol = protocol,
        .server = null
    };
}

/// Initializes a new socket for the specified IPv4 address / port pair
pub fn initIPv4(address: [4]u8, port: u16, protocol: SocketProtocol) Self {
    return .{
        .address_family = .IPv4,
        .listen_address = net.Address.initIp4(address, port),
        .posix_socket = null,
        .protocol = protocol,
        .server = null
    };
}

/// Starts listening on the socket.
/// `close` needs to be called after processing has been completed to free the binding.
/// Binding will fail if the address is invalid or no interface is bound to the address.
pub fn listen(self: *Self) !void {
    if(self.posix_socket != null) return error.AlreadyListening;

    switch (self.protocol) {
        SocketProtocol.UDP => try self.listenUDP(),
        SocketProtocol.TCP => try self.listenTCP()
    }
}

/// Accepts a connection, only applicable to TCP servers
pub fn accept(self: *Self) !net.Server.Connection {
    if (self.server == null) return error.NotAServer;
    return try self.server.?.accept();
}

/// Closes the server/socket
pub fn close(self: *Self) void {
    if (self.server != null) {
        // Note that calling `deinit()` on the server will also close the underlying socket.
        // Attempting to close both will trigger unreachable code.
        self.server.?.deinit();
    }
    else if (self.posix_socket != null) {
        posix.close(self.posix_socket.?);
    }

    self.posix_socket = null;
    self.server = null;
}

/// Binds a socket and starts a server that listens for TCP connections
fn listenTCP(self: *Self) !void {
    const sockfd = posix.socket(self.listen_address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch |err| {
        log.err("Could not initialize socket: {}", .{ err });
        return err;
    };

    var server = net.Server{
        .listen_address = undefined,
        .stream = .{ .handle = sockfd },
    };
    errdefer server.stream.close();

    var socklen = self.listen_address.getOsSockLen();
    posix.bind(sockfd, &self.listen_address.any, socklen) catch |err| {
        log.err("Could not bind address: {}", .{ err });
        return err;
    };
    errdefer self.close();

    posix.listen(sockfd, 128) catch |err| {
        log.err("Could not start server: {}", .{ err });
        return err;
    };
    errdefer self.close();

    var in_addr: net.Address = undefined;
    posix.getsockname(sockfd, &in_addr.any, &socklen) catch |err| {
        log.err("Could get socket name: {}", .{ err });
        return err;
    };

    log.info("Listening on {}", .{ in_addr });
    self.server = server;
    self.posix_socket = sockfd;
}

/// Binds a socket that listens for UDP connections
fn listenUDP(self: *Self) !void {
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