const std = @import("std");

const log = std.log;
const heap = std.heap;
const mem = std.mem;
const os = std.os;
const posix = std.posix;

const config = @import("./config.zig");
const server = @import("./server/server.zig");

var CANCELLATION_TOKEN = false;

pub fn main() !void {
    mapInterruptHandler();

    const cli_args = try parseCLIArgs();

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer {
        switch(gpa.deinit()) {
            .ok => {},
            .leak => log.debug("Detected leaks", .{})
        }
    }

    runServer(gpa.allocator(), cli_args.config_path);
}

// -------------------------------------------------------------------------------------
// CLI
// -------------------------------------------------------------------------------------

const CLIArguments = struct {
    config_path: []const u8
};

/// Parses the CLI arguments
fn parseCLIArgs() !CLIArguments {
    const argv = os.argv;
    if (argv.len < 2) return error.MissingArguments;

    const config_path = cStringToSlice(argv[1]);
    log.debug("Using configuration file: {s}", .{ config_path });

    return CLIArguments{
        .config_path = config_path
    };
}

/// Converts a zero terminated C-string to a slice
fn cStringToSlice(cstr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (cstr[len] != 0) len += 1;
    return cstr[0..len];
}

// -------------------------------------------------------------------------------------
// Server
// -------------------------------------------------------------------------------------

fn runServer(allocator: mem.Allocator, config_path: []const u8) void {
    if(config.parseConfigFile(allocator, config_path)) | parsed | {
        defer parsed.deinit();
        server.startServer(allocator, parsed.value.socket_configurations, &CANCELLATION_TOKEN);
    } else |err| {
        log.debug("Failed to load config file: {}", .{err});
    }
}

// -------------------------------------------------------------------------------------
// Interrupt handler
// -------------------------------------------------------------------------------------

fn sigaction_setCancellationToken(signal: i32) callconv(.C) void {
    log.debug("Received exit signal {}", .{ signal });
    CANCELLATION_TOKEN = true;
}

const INTERRUPT_SIGACTION = posix.Sigaction{
    .handler = .{ .handler = &sigaction_setCancellationToken },
    .mask = posix.empty_sigset,
    .flags = 0,
};

fn mapInterruptHandler() void {
    posix.sigaction(posix.SIG.INT, &INTERRUPT_SIGACTION, null);
}
