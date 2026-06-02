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

const ResponseError = error{
    Undefined,
    FileNotFound,
    AccessViolation,
    DiskFull,
    IllegalOp,
    UnknownId,
    FileExists,
    NoSuchUser,
};

const data_size = 512;
const packet_size = data_size + 4;
const max_retries = 2;
var current_block: u16 = 0;
var current_block_long: u64 = 0;
var bytes_sent: u64 = 0;
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
            if (i == 0) host_str = arg;
            if (i == 1) filename_str = arg;
        }

        if (i != 2) {
            printHelp();
            return;
        }

        addr = try net.IpAddress.parseLiteral(host_str);
        if (addr.getPort() == 0) addr.setPort(69);
        filename = try init.arena.allocator().alloc(u8, filename_str.len);
        @memcpy(filename, filename_str);
    }

    try beginTransfer(io, addr, filename);
}

fn beginTransfer(io: std.Io, addr: net.IpAddress, filename: []const u8) !void {
    // try to open the file before doing anything
    var file = try std.Io.Dir.cwd().openFile(
        io,
        filename,
        .{ .mode = .read_only },
    );
    defer file.close(io);

    const file_size = try file.length(io);

    var file_buffer: [4096]u8 = undefined;
    var recv_buffer: [data_size]u8 = @splat(0);
    const laddr = try net.IpAddress.parseLiteral("127.0.0.1");
    var s = try laddr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer s.close(io);

    try sendRequest(io, &s, &addr, filename);
    try receiveAck(io, &s, &recv_buffer);

    current_block +%= 1;
    current_block_long += 1;

    var reader = file.reader(io, &file_buffer);
    var packet: [packet_size]u8 = @splat(0);

    const start = std.Io.Timestamp.now(io, .awake);
    var progress_stamp = std.Io.Timestamp.now(io, .awake);

    std.debug.print("\x1b[?25l", .{});
    defer std.debug.print("\x1b[?25h", .{});

    std.debug.print("file size: {B}\n", .{file_size});
    var transfer_percentage: usize = 0;

    while (true) {
        const read = try reader.interface.readSliceShort(packet[4..]);
        if (read == 0) break;

        std.mem.writeInt(u16, packet[0..2], @intFromEnum(OpCode.data), .big);
        std.mem.writeInt(u16, packet[2..4], current_block, .big);
        try s.send(io, &server_ip.?, packet[0 .. read + 4]);

        // note: can't use receiveTimeout at the moment, so no resends
        // could maybe impl manually but cba
        try receiveAck(io, &s, &recv_buffer);

        bytes_sent += read;

        if (read < data_size) break;

        current_block +%= 1;
        current_block_long += 1;

        const new_tpct = 10000 / ((file_size * 100) / bytes_sent);
        if (progress_stamp.untilNow(io, .awake).toMilliseconds() >= 250 and
            transfer_percentage != new_tpct)
        {
            transfer_percentage = new_tpct;
            std.debug.print("\r{d}%", .{transfer_percentage});
            progress_stamp = std.Io.Timestamp.now(io, .awake);
        }
    }

    const end = start.untilNow(io, .awake);

    std.debug.print("\r{d}%\n", .{100});
    std.debug.print(
        "sent {d} blocks, worth {B}, in {d} second(s)\n",
        .{ current_block_long, bytes_sent, end.toSeconds() },
    );
}

fn sendRequest(
    io: std.Io,
    socket: *net.Socket,
    addr: *const net.IpAddress,
    filename: []const u8,
) !void {
    var buffer: [data_size]u8 = @splat(0);
    std.mem.writeInt(u16, buffer[0..2], 2, .big);
    @memcpy(buffer[2 .. 2 + filename.len], filename);
    buffer[2 + filename.len] = 0;
    @memcpy(buffer[3 + filename.len .. filename.len + 9], "octet\x00");
    try socket.send(io, addr, buffer[0 .. filename.len + 9]);
}

fn receiveAck(io: std.Io, socket: *net.Socket, buf: []u8) !void {
    const recv = try socket.receive(io, buf);
    const data = recv.data;
    if (server_ip == null) server_ip = recv.from;

    const op: u16 = std.mem.readInt(u16, data[0..2], .big);

    switch (@as(OpCode, @enumFromInt(op))) {
        .ack => {
            const block: u16 = std.mem.readInt(u16, data[2..4], .big);
            if (block != current_block) return error.IncorrectBlock;
        },
        .err => {
            const error_code: u16 = std.mem.readInt(u16, data[2..4], .big);
            const zero = std.mem.indexOfScalar(u8, buf, 0) orelse
                return error.MissingNullTerminator;
            std.log.err("{s}\n", .{buf[0..zero]});
            return switch (error_code) {
                0 => ResponseError.Undefined,
                1 => ResponseError.FileNotFound,
                2 => ResponseError.AccessViolation,
                3 => ResponseError.DiskFull,
                4 => ResponseError.IllegalOp,
                5 => ResponseError.UnknownId,
                6 => ResponseError.FileExists,
                7 => ResponseError.NoSuchUser,
                else => error.UnknownErrorCode,
            };
        },
        else => return error.InvalidOpCode,
    }
}

fn printHelp() void {
    std.debug.print("ztftp ip[:port] filename\n", .{});
}
