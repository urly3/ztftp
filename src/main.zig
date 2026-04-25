const std = @import("std");
const net = std.Io.net;

const OpCode = enum(u16) {
    none,
    rrq,
    wrq,
    data,
    ack,
    err,
};

const ErrorCode = enum(u16) {
    undefined,
    file_not_found,
    access_violation,
    disk_full,
    illegal_op,
    unknown_id,
    file_exists,
    no_such_user,
};

const max_block_size = 512;
const max_retries = 2;
var current_block: u32 = 0;
var bytes_sent: u64 = 0;
var resends: u16 = 0;

pub fn main(init: std.process.Init) !void {
    var addr: net.IpAddress = undefined;
    var filename: []u8 = undefined;
    const io = init.io;

    {
        var host_str: []const u8 = undefined;
        var filename_str: []const u8 = undefined;

        var it = try init.minimal.args.iterateAllocator(init.gpa);
        defer it.deinit();

        // skip first path arg
        _ = it.skip();

        var i: usize = 0;
        while (it.next()) |arg| : (i += 1) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printHelp();
                return;
            }

            if (i == 0) {
                host_str = arg;
            }

            if (i == 1) {
                filename_str = arg;
            }
        }

        if (i != 2) {
            std.debug.print("i = {d}\n", .{i});
            printHelp();
            return;
        }

        addr = try net.IpAddress.parseLiteral(host_str);
        filename = try init.arena.allocator().alloc(u8, filename_str.len);
        @memcpy(filename, filename_str);
    }

    try start(io, addr, filename);
}

fn start(io: std.Io, addr: net.IpAddress, filename: []const u8) !void {
    // try to open the file before doing anything

    var buffer: [512]u8 = @splat(0);
    var stream = try addr.connect(io, .{ .mode = .dgram, .protocol = .udp });
    var w = stream.writer(io, &buffer).interface;
    try sendRequest(&w, filename);
}

fn sendRequest(w: *std.Io.Writer, filename: []const u8) !void {
    try w.writeInt(u16, 2, .big);
    _ = try w.write(filename);
    try w.flush();
}

fn recieveAck(r: *std.Io.Reader) !bool {
    _ = r; // autofix
}

fn sendBlock(w: *std.Io.Writer) !void {
    _ = w; // autofix
}

fn printHelp() void {
    std.debug.print("ztftp ip:port filename", .{});
}
