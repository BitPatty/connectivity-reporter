const std = @import("std");

const enums = std.enums;
const fmt = std.fmt;
const fs = std.fs;
const json = std.json;
const log = std.log;
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const process = std.process;

const SocketProtocol = @import("./enums.zig").SocketProtocol;

/// Maximum allowed file size for the config file
const DEFAULT_MAX_CONFIG_FILE_SIZE = 1024 * 1024;

pub const SocketConfiguration = struct {
    /// The protocol of the socket
    protocol: SocketProtocol,
    /// The address to bind
    bind_address: []const u8,
    /// The port to bind
    bind_port: u16,

    /// Parses the socket configuration from the JSON string.
    /// This is done manually as the ip address should be read as a slice of bytes rather
    /// than a string.
    pub fn jsonParse(allocator: mem.Allocator, scanner: *json.Scanner, _: json.ParseOptions) !@This() {
        log.debug("Parsing socket configuration", .{});
        if (try scanner.next() != json.Token.object_begin)
            return error.UnexpectedToken;

        var result = @This(){
            .protocol = SocketProtocol.UDP,
            .bind_address = "",
            .bind_port = 0,
        };

        while(true) {
            const next_token = try scanner.nextAlloc(allocator, .alloc_if_needed);

            switch (next_token) {
                .string, .allocated_string => | key | {
                    const value_token = try scanner.nextAlloc(allocator, .alloc_if_needed);

                    if (mem.eql(u8, key, "bind_address")) {
                        result.bind_address = try parseBindAddressValueJsonToken(allocator, value_token);
                    }
                    else if (mem.eql(u8, key, "bind_port")) {
                        result.bind_port = try parsePortValueJsonToken(value_token);
                    }
                    else if (mem.eql(u8, key, "protocol")) {
                        result.protocol = try parseSocketProtocolValueJsonToken(value_token);
                    }
                    else {
                        log.err("Encountered unknown field '{s}'", .{ key });
                        return error.UnknownField;
                    }
                },
                .object_end => {
                    break;
                },
                else => {
                    log.err("Expected key or end of object, got '{}'", .{ next_token });
                    return error.UnexpectedToken;
                }
            }
        }

        // Ensure the values are configured / all keys were present
        if (mem.eql(u8, result.bind_address, "")) {
            log.err("Missing bind_address", .{});
            return error.SyntaxError;
        }

        if (result.bind_port == 0) {
            log.err("Missing bind_port", .{});
            return error.SyntaxError;
        }

        log.debug("Parsed socket configuration: {}", .{ result });
        return result;
    }
};

/// The configuraiton for the application
pub const ApplicationConfiguration = struct {
    /// The socket configurations
    socket_configurations: []SocketConfiguration
};

pub const ConfigParseError = error {
    /// The max config file size was exceeded (see `parseConfigFile()`)
    MaxFileSizeExceeded,
    /// The config file could not be opened
    OpenFailure,
    /// The config file could not be read
    ReadFailure,
    /// The config file could not be parsed. This is usually a user error
    ParseFailure
};

/// Parses the config file at the specified location.
///
/// ```zig
/// parseConfigFile(allocator, "/path/to/file.json");
/// ```
///
/// The path must be absolute.
///
/// The file size may not exceed `DEFAULT_MAX_CONFIG_FILE_SIZE`. The limit can be increased by
/// overriding it via the `CONNLOG_MAX_CONFIG_FILE_SIZE` environment variable. The environment
/// variable is ignored if its value is invalid. Exceeding the limit returns a `MaxFileSizeExceeded`
/// error.
///
pub fn parseConfigFile(allocator: mem.Allocator, filePath: []const u8) ConfigParseError!json.Parsed(ApplicationConfiguration) {
    const file = fs.openFileAbsolute(filePath, fs.File.OpenFlags{}) catch | err | {
        log.err("Could not open config file: {}", .{ err });
        return ConfigParseError.OpenFailure;
    };
    defer file.close();

    ensureFileSizeLimit(&file) catch | err | {
        if (err == ConfigParseError.MaxFileSizeExceeded) return ConfigParseError.MaxFileSizeExceeded;
        log.err("Could not stat file: {}", .{ err });
        return ConfigParseError.ReadFailure;
    };

    const file_contents = file.readToEndAlloc(allocator, DEFAULT_MAX_CONFIG_FILE_SIZE) catch | err | {
        log.err("Could not read file: {}", .{ err });
        return ConfigParseError.ReadFailure;
    };
    defer allocator.free(file_contents);

    return json.parseFromSlice(ApplicationConfiguration, allocator, file_contents, .{.allocate = .alloc_always}) catch | err | {
        log.err("Could not parse file: {}", .{ err });
        return ConfigParseError.ParseFailure;
    };
}

/// Ensures the specified config file does not exceed the file size limit.
/// This is to prevent loading arbitrarily large files into memory.
/// The file size limit can be overriden via the `CONNLOG_MAX_CONFIG_FILE_SIZE` environment variable.
fn ensureFileSizeLimit(file: *const fs.File) (ConfigParseError || fs.File.StatError)!void {
    const stats = try file.stat();

    if (loadMaxFileSizeFromEnv()) | env_size | {
        if (env_size != null) {
            if(stats.size > env_size.?) return ConfigParseError.MaxFileSizeExceeded;
            return;
        }
    } else | err | {
        switch (err) {
            process.ParseEnvVarIntError.EnvironmentVariableNotFound => {},
            process.ParseEnvVarIntError.InvalidCharacter,
            process.ParseEnvVarIntError.Overflow => log.warn("Invalid config size limit: {}", .{ err })
        }
    }

    if (stats.size > DEFAULT_MAX_CONFIG_FILE_SIZE) return ConfigParseError.MaxFileSizeExceeded;
}

/// Loads the max file size configured via the CONNLOG_MAX_CONFIG_FILE_SIZE environment variable
fn loadMaxFileSizeFromEnv() process.ParseEnvVarIntError!?u32 {
    return try process.parseEnvVarInt("CONNLOG_MAX_CONFIG_FILE_SIZE", u32, 10);
}

/// Parses the socket protocol value token from the JSON configuration
fn parseSocketProtocolValueJsonToken(value_token: json.Token) !SocketProtocol {
    switch (value_token) {
        .string, .allocated_string => | value | {
            return try parseSocketProtocolFromString(value);
        },
        else => {
            log.err("Expected string value, got '{}'", .{ value_token });
            return error.UnexpectedToken;
        }
    }
}

/// Converts a protocol string to the respective socket protocol
fn parseSocketProtocolFromString(value: []const u8) !SocketProtocol {
    if (mem.eql(u8, value, "UDP")) {
        return SocketProtocol.UDP;
    }

    log.err("Expected protocol, got '{s}'", .{ value });
    return error.UnexpectedToken;
}

/// Parses the bind address value token from the JSON configuration and validates its format.
/// Returns a slice of bytes representing the address.
fn parseBindAddressValueJsonToken(allocator: mem.Allocator, value_token: json.Token) ![]u8 {
    switch (value_token) {
        .string, .allocated_string => | value | {
            return try parseIPAddressFromString(allocator, value);
        },
        else => {
            log.err("Expected string value, got '{}'", .{ value_token });
            return error.UnexpectedToken;
        }
    }
}

/// Converts an IP address string to a slice of bytes. Works for IPv4 and IPv6 addresses,
/// including link-local addresses.
fn parseIPAddressFromString(allocator: mem.Allocator, address_string: []const u8) error{SyntaxError, OutOfMemory}![]u8 {
    const parsed_address = net.Address.resolveIp(address_string, 0) catch return error.SyntaxError;

    switch (parsed_address.any.family) {
        posix.AF.INET => {
            const allocated_address = try allocator.alloc(u8, 4);
            @memcpy(allocated_address, mem.asBytes(&parsed_address.in.sa.addr));
            log.debug("Parsed IPv4 address: '{d}'", .{ allocated_address });
            return allocated_address;
        },
        posix.AF.INET6 => {
            const allocated_address = try allocator.alloc(u8, 16);
            @memcpy(allocated_address, &parsed_address.in6.sa.addr);
            log.debug("Parsed IPv6 address '{d}'", .{ allocated_address });
            return allocated_address;
        },
        else => {
            log.err("Unsupported address family '{}'", .{ parsed_address.any.family });
            return error.SyntaxError;
        }
    }
}

/// Parses the port value token from the JSON configuration and validates its range
fn parsePortValueJsonToken(value_token: json.Token) !u16 {
    switch (value_token) {
        .number, .allocated_number => | value | {
            return try parsePortFromDigitsString(value);
        },
        else => {
            log.err("Expected numeric value, got '{}'", .{ value_token });
            return error.InvalidNumber;
        }
    }
}

/// Parses a port from a a string containing digits, e.g. "1234" -> 1234.
/// Also validates whether the port is in a valid range.
fn parsePortFromDigitsString(port_string: []const u8) (fmt.ParseIntError || error{ UnexpectedToken })!u16 {
    const parsed_port = try fmt.parseInt(u16, port_string, 10);
    log.debug("Parsed port: {d}", .{ parsed_port });

    if(parsed_port == 0 or parsed_port > 65535) return {
        log.err("Port '{d}' is outside valid range (1 to 65535)", .{ parsed_port });
        return error.UnexpectedToken;
    };

    return parsed_port;
}
