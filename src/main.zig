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
    const laddr = try net.IpAddress.parseLiteral("127.0.0.1");
    var s = try laddr.bind(io, .{ .mode = .dgram, .protocol = .udp });

    // send the request to write and wait for ack
    try sendRequest(io, &s, &addr, filename, &buffer);

    // block of data and wait for ack in a loop

    while (true) {
        // send data blocks and receive acks in a loop
    }
}

fn sendRequest(io: std.Io, socket: *net.Socket, addr: *const net.IpAddress, filename: []const u8, buffer: []u8) !void {
    std.mem.writeInt(u16, @ptrCast(buffer), 2, .big);
    @memcpy(buffer[2 .. 2 + filename.len], filename);
    buffer[2 + filename.len] = 0;
    @memcpy(buffer[3 + filename.len .. 3 + filename.len + 6], "octet\x00");
    std.debug.print("sent: {any}\n", .{buffer[0 .. 2 + filename.len + 1 + 5 + 1]});
    try socket.send(io, addr, buffer[0 .. 2 + filename.len + 1 + 5 + 1]);

    try receiveAck(io, socket);
}

fn receiveAck(io: std.Io, socket: *net.Socket) !void {
    var buf: [512]u8 = undefined;
    const recv = try socket.receive(io, &buf);
    const data = recv.data;

    const op: u16 = std.mem.readInt(u16, data[0..2], .big);
    const block: u16 = std.mem.readInt(u16, data[2..4], .big);

    if (op != @intFromEnum(OpCode.ack) or block != current_block) {
        return error.incorrectBlock;
    }

    // TODO: handle error response or something

    std.debug.print("ack received for block {d}. recv {any}\n", .{ block, recv.data });
}

// fn sendBlock(socket: *net.Socket) !void {}

fn printHelp() void {
    std.debug.print("ztftp ip:port filename", .{});
}
