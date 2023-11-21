const std = @import("std");
const zap = @import("zap");

pub fn replyWithError(alloc: std.mem.Allocator, r: zap.SimpleRequest, error_msg: []const u8) void {
    const msg = std.fmt.allocPrint(alloc,
        \\{{ "error" : "{s}"}}
    , .{error_msg}) catch {
        // send fixed message that does not need to be allocated
        const fixed_msg =
            \\{{ "status": "error" }}
        ;
        std.log.err("replyWithError: {s}\n", .{fixed_msg});
        r.sendJson(fixed_msg) catch |err| {
            std.log.err("Error sending JSON error message `{s}`: {any}", .{ fixed_msg, err });
        };
        return;
    };
    defer alloc.free(msg);
    r.setStatus(.internal_server_error);
    std.log.err("replyWithError: {s}\n", .{error_msg});
    r.sendJson(msg) catch |err| {
        std.log.err("Error sending JSON error message `{s}`: {any}", .{ msg, err });
    };
}
