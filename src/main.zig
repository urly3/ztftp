const std = @import("std");

const op_code = union(enum) {
    none: u16,
    rrq: u16,
    wrq: u16,
    data: u16,
    ack: u16,
    err: u16,
};

const error_code = union(enum) {
    undefined: u16,
    file_not_found: u16,
    access_violation: u16,
    disk_full: u16,
    illegal_op: u16,
    unknown_id: u16,
    file_exists: u16,
    no_such_user: u16,
};
