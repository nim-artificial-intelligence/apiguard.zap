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

/// Mutex to protect our timestamps collection
timestamps_mutex: std.Thread.Mutex = .{},

/// Mutex to serialize all delays
delay_mutex: std.Thread.Mutex = .{},

/// Mutex to access / update params
params_mutex: std.Thread.Mutex = .{},

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
            .post = post, // post,
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
        \\{{ "success": false, "status": "error", "error": "unauthorized" }}
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

    {
        // --- PARAM LOCK ---
        self.params_mutex.lock();
        defer self.params_mutex.unlock();
        try std.json.stringify(.{ .success = true, .current_rate_limit = self.rate_limit, .delay_ms = self.delay_ms }, .{}, string.writer());
    }
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

fn post(e: *zap.SimpleEndpoint, r: zap.SimpleRequest) void {
    const self = @fieldParentPtr(Self, "endpoint", e);
    self.postInternal(r) catch |err| {
        var error_buf: [1024]u8 = undefined;
        const error_msg = std.fmt.bufPrint(&error_buf, "{any}", .{err}) catch "Internal server error";
        replyWithError(self.allocator, r, error_msg);
    };
}

fn postInternal(self: *Self, r: zap.SimpleRequest) !void {
    if (r.path) |p| {
        const local_path = p[(self.slug.len)..];
        std.debug.print("LOCAL PATH IS {s}\n ", .{local_path});

        if (std.mem.eql(u8, local_path, "/set_rate_limit")) {
            return self.set_rate_limit(r);
        }
    }
    return error.NoSuchEndpoint;
}

fn set_rate_limit(self: *Self, r: zap.SimpleRequest) !void {
    // first, parse the params out of the request
    if (r.body) |body| {
        const JsonSchema = struct {
            new_limit: ?usize = null,
            new_delay: ?usize = null,
        };
        var parsed = try self.allocator.create(std.json.Parsed(JsonSchema));
        parsed.* = try std.json.parseFromSlice(JsonSchema, self.allocator, body, .{});
        std.log.debug("Parsed json: {}", .{parsed.value});

        // second, validate param ranges
        if (parsed.value.new_limit == null and parsed.value.new_delay == null) {
            return replyWithError(self.allocator, r, "All values null!");
        }

        const Response = struct {
            new_rate_limit: ?usize = null,
            new_delay: ?usize = null,
        };

        var response = Response{};
        // third, update paramas
        {
            // --- PARAM LOCK ---
            self.params_mutex.lock();
            defer self.params_mutex.unlock();

            if (parsed.value.new_limit) |new_limit| {
                self.rate_limit = new_limit;
                response.new_rate_limit = new_limit;
            }
            if (parsed.value.new_delay) |new_delay| {
                self.delay_ms = new_delay;
                response.new_delay = new_delay;
            }
        }

        // forth, send response
        var json_buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&json_buf);
        var string = std.ArrayList(u8).init(fba.allocator());
        try std.json.stringify(response, .{}, string.writer());
        return r.sendJson(string.items);
    } else {
        // no body
        return replyWithError(self.allocator, r, "Empty body!");
    }
}
