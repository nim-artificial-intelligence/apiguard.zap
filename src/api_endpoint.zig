const std = @import("std");
const zap = @import("zap");
const replyWithError = @import("endpoint_utils.zig").replyWithError;

// we abuse a priority deque as normal deque
const Deque = std.PriorityDequeue(i64, void, lessThanComparison);
const Order = std.math.Order;

fn lessThanComparison(context: void, a: i64, b: i64) Order {
    _ = context;
    return std.math.order(a, b);
}

allocator: std.mem.Allocator,
timestamps: Deque,
timestamps_mutex: std.Thread.Mutex = .{},
delay_mutex: std.Thread.Mutex = .{},
endpoint: zap.SimpleEndpoint,
slug: []const u8,
rate_limit: usize,
delay_ms: usize,

const Self = @This();

pub fn init(alloc: std.mem.Allocator, slug: []const u8, rate_limit: usize, delay_ms: usize) Self {
    return .{
        .allocator = alloc,
        .timestamps = Deque.init(alloc, {}),
        .slug = slug, // we don't take a copy!
        .rate_limit = rate_limit,
        .delay_ms = delay_ms,
        .endpoint = zap.SimpleEndpoint.init(.{
            .path = slug,
            .get = get,
            .post = null, // post,
            .put = null,
            .delete = null,
            .unauthorized = unauthorized,
        }),
    };
}

pub fn getEndpoint(self: *Self) *zap.SimpleEndpoint {
    return &self.endpoint;
}

fn unauthorized(e: *zap.SimpleEndpoint, r: zap.SimpleRequest) void {
    _ = e;
    std.log.warn("UNAUTHORIZED", .{});
    r.setStatus(.unauthorized);
    const msg =
        \\{{ "status": "error", "error": "unauthorized" }}
    ;
    r.sendJson(msg) catch |err| {
        std.log.err("Error sending JSON error message `{s}`: {any}", .{ msg, err });
    };
}

fn get(e: *zap.SimpleEndpoint, r: zap.SimpleRequest) void {
    const self = @fieldParentPtr(Self, "endpoint", e);
    self.getInternal(r) catch |err| {
        var error_buf: [1024]u8 = undefined;
        const error_msg = std.fmt.bufPrint(&error_buf, "{any}", .{err}) catch "Internal server error";
        replyWithError(self.allocator, r, error_msg);
    };
}

fn getInternal(self: *Self, r: zap.SimpleRequest) !void {
    if (r.path) |p| {
        const local_path = p[(self.slug.len)..];
        std.debug.print("LOCAL PATH IS {s}\n ", .{local_path});

        if (std.mem.eql(u8, local_path, "/request_access")) {
            return self.requestAccess(r);
        }

        if (std.mem.eql(u8, local_path, "/get_rate_limit")) {
            return self.getRateLimit(r);
        }
    }
    return error.NoSuchEndpoint;
}

fn getRateLimit(self: *Self, r: zap.SimpleRequest) !void {
    r.setStatus(.ok);
    var json_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&json_buf);
    var string = std.ArrayList(u8).init(fba.allocator());

    try std.json.stringify(.{ .current_rate_limit = self.rate_limit, .delay_ms = self.delay_ms }, .{}, string.writer());
    return r.sendJson(string.items);
}

fn requestAccess(self: *Self, r: zap.SimpleRequest) !void {
    _ = self;
    r.setStatus(.ok);
    r.sendJson(
        \\{{ "status": "OK", "delay_ms": 30 }}
    ) catch |err| {
        std.log.err("Could not send response in requestAccess: {any}", .{err});
    };
}
