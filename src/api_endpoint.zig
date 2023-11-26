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

/// Mutex to access / update params
params_mutex: std.Thread.Mutex = .{},

endpoint: zap.SimpleEndpoint,
slug: []const u8,
rate_limit: i64,
delay_ms: i64,

const Self = @This();

pub fn init(alloc: std.mem.Allocator, slug: []const u8, rate_limit: i64, delay_ms: i64) Self {
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
    r.parseQuery();
    const handle_delay: bool = blk: {
        if (r.getParamStr("handle_delay", self.allocator, false)) |maybe_str| {
            if (maybe_str) |*s| {
                defer s.deinit();
                if (std.mem.eql(u8, s.str, "true")) {
                    break :blk true;
                }
            }
        } else |_| {
            // getting param str failed
            break :blk false;
        }
        break :blk false;
    };

    const current_time_ms = std.time.milliTimestamp();

    var json_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&json_buf);
    var string = std.ArrayList(u8).init(fba.allocator());
    var delay_ms = self.delay_ms;
    var req_per_min: i64 = 0;

    {
        self.timestamps_mutex.lock();
        defer self.timestamps_mutex.unlock();

        // remove old timestamps outside of our 60s window
        while (self.timestamps.count() > 0 and current_time_ms - self.timestamps.peekMin().? > 60 * std.time.ms_per_s) { // TODO: maybe make this safer by not using .? here:
            _ = self.timestamps.removeMin();
        }

        req_per_min = self.get_current_req_per_min();

        if (self.adjust_delay_under_load(req_per_min, current_time_ms)) |adjusted_delay| {
            delay_ms = adjusted_delay;
        }

        if (req_per_min < self.rate_limit) {
            // we've made less requests than are allowed per minute within the last minute
            // so we don't need to delay. we will delay for the default delay in that case
            try self.timestamps.add(current_time_ms + delay_ms); // add the time in the future when this request won't count anymore: after the delay
        } else {
            //
            // we usually never get here if clients are behaving OR if they use handle_delay=true
            //

            // we need to work out when we can make a request again
            const oldest_request_time_ms = self.timestamps.peekMin().?;
            std.log.debug("\n\n\n************************************************************\n\n", .{});
            // calculate the delay:
            delay_ms = 60 * std.time.ms_per_s - (current_time_ms - oldest_request_time_ms);

            if (delay_ms < self.delay_ms) delay_ms = self.delay_ms;

            if (self.adjust_delay_under_load(req_per_min, current_time_ms)) |adjusted_delay| {
                delay_ms = adjusted_delay;
            }

            try self.timestamps.add(current_time_ms + delay_ms);
        }
    }
    r.setStatus(.ok);
    if (handle_delay) {
        std.log.debug("Sleeping for {} ms", .{delay_ms});
        var delay_ns: u64 = @intCast(delay_ms);
        delay_ns *= std.time.ns_per_ms;

        // TODO: demonstrate if or that this always works out well in parallel scenarios
        std.time.sleep(delay_ns);

        // send response
        try std.json.stringify(.{ .delay_ms = 0, .current_req_per_min = req_per_min, .server_side_delay = delay_ms }, .{}, string.writer());
        return r.sendJson(string.items);
    } else {
        // send response
        try std.json.stringify(.{ .delay_ms = delay_ms, .current_req_per_min = req_per_min, .server_side_delay = 0 }, .{}, string.writer());
        return r.sendJson(string.items);
    }
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
            new_limit: ?i64 = null,
            new_delay: ?i64 = null,
        };
        var parsed = try self.allocator.create(std.json.Parsed(JsonSchema));
        parsed.* = try std.json.parseFromSlice(JsonSchema, self.allocator, body, .{});
        std.log.debug("Parsed json: {}", .{parsed.value});

        // second, validate param ranges
        if (parsed.value.new_limit == null and parsed.value.new_delay == null) {
            return replyWithError(self.allocator, r, "All values null!");
        }

        const Response = struct {
            new_rate_limit: ?i64 = null,
            new_delay: ?i64 = null,
        };

        var response = Response{};
        // third, update paramas
        {
            // --- PARAM LOCK ---
            self.params_mutex.lock();
            defer self.params_mutex.unlock();

            if (parsed.value.new_limit) |new_limit| {
                if (new_limit < 0) {
                    return replyWithError(self.allocator, r, "limit must be positive!");
                }
                self.rate_limit = new_limit;
                response.new_rate_limit = new_limit;
            }
            if (parsed.value.new_delay) |new_delay| {
                if (new_delay < 0) {
                    return replyWithError(self.allocator, r, "delay must be positive!");
                }
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

/// ONLY USE ON LOCKED timestamps!
fn get_current_req_per_min(self: *Self) i64 {
    // check how many requests fall < current_time_ms
    const current_time_ms = std.time.milliTimestamp();
    var it = self.timestamps.iterator();
    var count: i64 = 0;
    while (it.next()) |timestamp| {
        if (timestamp < current_time_ms) {
            count += 1;
        }
    }
    return count;
}

/// now check if we need to adjust the delay
/// our first thing is:
/// if we're > 75% of limit:
/// num_remaining_requests: limit - current_number_of_requ_per_min
/// num_remaining_milliseconds_in_second: current_time_ms - self.timestamps.peekMin().?
/// divide num_remaining_milliseconds_in_second / num_remaining_requests
fn adjust_delay_under_load(self: *Self, req_per_min: i64, current_time_ms: i64) ?i64 {
    const Escalation = struct {
        at_percent_of_limit: u8,
        factor_of_delay: i64,
    };
    const escalations = [_]Escalation{
        // .{ .at_percent_of_limit = 75, .factor_of_delay = 100 },
        // .{ .at_percent_of_limit = 50, .factor_of_delay = 105 },
        .{ .at_percent_of_limit = 75, .factor_of_delay = 100 },
        .{ .at_percent_of_limit = 50, .factor_of_delay = 100 },
        .{ .at_percent_of_limit = 25, .factor_of_delay = 100 },
        .{ .at_percent_of_limit = 0, .factor_of_delay = 100 },
    };
    for (escalations) |escalation| {
        // if req_per_min > rate_limt * escalation_percent / 100
        if (req_per_min > @divTrunc(self.rate_limit * escalation.at_percent_of_limit, 100)) {
            var num_remaining_requests = self.rate_limit - req_per_min;
            const consumed_ms_of_last_60s = (current_time_ms - self.timestamps.peekMin().?);
            const num_remaining_milliseconds_in_minute = 60 * std.time.ms_per_s - consumed_ms_of_last_60s;
            var delay_ms = blk: {
                if (num_remaining_requests > 0) {
                    // delay_ms = (num_remaining_milliseconds_in_minute / num_remaining_requests) * escalation_factor / 100
                    break :blk @divTrunc(@divTrunc(num_remaining_milliseconds_in_minute, num_remaining_requests) * escalation.factor_of_delay, 100) + 1;
                } else {
                    break :blk num_remaining_milliseconds_in_minute;
                }
            };

            std.log.debug("\n\n\nHIT {} --> {}\n\n\n", .{ escalation, delay_ms });

            // just to be sure
            if (delay_ms < self.delay_ms) delay_ms = self.delay_ms;
            return delay_ms;
        }
    }
    return null;
}
