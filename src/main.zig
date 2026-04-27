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
var current_block: u16 = 0;
var current_block_long: u64 = 0;
var bytes_sent: u64 = 0;
var resends: u16 = 0;
var server_ip: ?net.IpAddress = null;

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
    var file = try std.Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_only });
    defer file.close(io);

    var data_buffer: [512]u8 = @splat(0);
    const laddr = try net.IpAddress.parseLiteral("127.0.0.1");
    var s = try laddr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer s.close(io);

    // send the request to write and wait for ack
    try sendRequest(io, &s, &addr, filename);
    try receiveAck(io, &s);
    current_block = @addWithOverflow(current_block, 1)[0];
    current_block_long += 1;
    var reader = file.reader(io, &data_buffer);

    // send block of data and wait for ack in a loop
    while (true) {
        const read = try reader.interface.readSliceShort(&data_buffer);
        if (read == 0) {
            break;
        }

        try sendBlock(io, &s, data_buffer[0..read]);
        // TODO: handle wrong acks with resends or something
        try receiveAck(io, &s);
        current_block = @addWithOverflow(current_block, 1)[0];
        current_block_long += if (read == 512) 1 else 0;
        bytes_sent += read;
    }

    std.debug.print("sent {d} blocks, worth {d} bytes\n", .{ current_block_long, bytes_sent });
}

fn sendRequest(io: std.Io, socket: *net.Socket, addr: *const net.IpAddress, filename: []const u8) !void {
    var buffer: [512]u8 = @splat(0);
    std.mem.writeInt(u16, buffer[0..2], 2, .big);
    @memcpy(buffer[2 .. 2 + filename.len], filename);
    buffer[2 + filename.len] = 0;
    @memcpy(buffer[3 + filename.len .. 3 + filename.len + 6], "octet\x00");
    // std.debug.print("sent: {any}\n", .{buffer[0 .. 2 + filename.len + 1 + 5 + 1]});
    try socket.send(io, addr, buffer[0 .. 2 + filename.len + 1 + 5 + 1]);
}

fn receiveAck(io: std.Io, socket: *net.Socket) !void {
    var buf: [512]u8 = undefined;
    const recv = try socket.receive(io, &buf);
    const data = recv.data;
    if (server_ip == null) {
        server_ip = recv.from;
    }

    const op: u16 = std.mem.readInt(u16, data[0..2], .big);
    const block: u16 = std.mem.readInt(u16, data[2..4], .big);

    if (op != @intFromEnum(OpCode.ack)) {
        // TODO: handle error response or something
        return error.ErrorReceived;
    }

    if (block != current_block) {
        // std.debug.print("ERR: ack received for block {d}. recv {any}\n", .{ block, recv.data });
        return error.IncorrectBlock;
    }

    // std.debug.print("ack received for block {d}. recv {any}\n", .{ block, recv.data });
}

fn sendBlock(io: std.Io, socket: *net.Socket, data: []u8) !void {
    var buf: [518]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], @intFromEnum(OpCode.data), .big);
    std.mem.writeInt(u16, buf[2..4], current_block, .big);
    @memcpy(buf[4 .. data.len + 4], data);
    try socket.send(io, &server_ip.?, buf[0 .. 4 + data.len]);

    // std.debug.print("sent block {d}: {any}\n", .{ current_block, buf[0 .. data.len + 4] });
}

fn printHelp() void {
    std.debug.print("ztftp ip:port filename\n", .{});
}
