const std = @import("std");

const ClientRequest = struct {
    uri: std.Uri,
    handle_delay: bool,
};

const ServerResponse = struct {
    delay_ms: usize,
    current_req_per_min: usize,
    server_side_delay: usize,
};

const Transaction = struct {
    sequence_number: usize,
    request_timestamp_ms: isize,
    request: ClientRequest,
    response_timestamp_ms: ?isize = null,
    response: ?ServerResponse = null,
};

const TransactionLog = struct {
    allocator: std.mem.Allocator,
    transactions: std.ArrayList(Transaction),
    transaction_lock: std.Thread.Mutex = .{},
    _current_sequence_number: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .transactions = std.ArrayList(Transaction).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.transactions.deinit();
    }

    pub fn newTransaction(self: *Self, url: []const u8) !Transaction {
        {
            self.transaction_lock.lock();
            defer self.transaction_lock.unlock();
            self._current_sequence_number += 1;
        }
        const uri = try std.Uri.parse(url);
        const handle_delay = blk: {
            if (uri.query) |query| {
                const query_field = "handle_delay=";
                if (std.mem.indexOf(u8, query, query_field)) |pos| {
                    if (std.mem.startsWith(u8, query[pos + query_field.len ..], "true")) {
                        break :blk true;
                    }
                }
            }
            break :blk false;
        };
        return Transaction{
            .sequence_number = self._current_sequence_number,
            .request_timestamp_ms = std.time.milliTimestamp(),
            .request = ClientRequest{ .uri = uri, .handle_delay = handle_delay },
        };
    }

    pub fn addTransaction(self: *Self, transaction: Transaction) !void {
        self.transaction_lock.lock();
        defer self.transaction_lock.unlock();
        try self.transactions.append(transaction);
    }
};

fn makeRequest(a: std.mem.Allocator, url: []const u8, auth_bearer: []const u8, transaction_log: *TransactionLog) !void {
    var transaction = try transaction_log.newTransaction(url);

    var h = std.http.Headers{ .allocator = a };
    defer h.deinit();
    try h.append("Authorization", auth_bearer);

    var http_client: std.http.Client = .{ .allocator = a };
    defer http_client.deinit();

    var req = try http_client.request(.GET, transaction.request.uri, h, .{});
    defer req.deinit();

    try req.start();
    try req.wait();

    var buffer: [1024]u8 = undefined;
    const rsize = try req.readAll(&buffer);
    transaction.response_timestamp_ms = std.time.milliTimestamp();

    const parsed = try std.json.parseFromSlice(ServerResponse, a, buffer[0..rsize], .{});
    defer parsed.deinit();
    transaction.response = parsed.value;
    std.log.debug("{}", .{transaction});
}

fn makeRequestThread(a: std.mem.Allocator, url: []const u8, auth_bearer: []const u8, tlog: *TransactionLog) !std.Thread {
    return try std.Thread.spawn(.{}, makeRequest, .{ a, url, auth_bearer, tlog });
}

pub fn usage() !void {
    const stdout = std.io.getStdOut().writer();
    const progname = "clientbot";
    try stdout.print("Usage: {s} num-requests base-url auth-token handle_delay outfile\n", .{progname});
}

const Args = struct {
    progname: []const u8 = "clientbot",
    num_requests: usize = 0,
    base_url: []const u8 = "",
    auth_bearer: []const u8 = "",
    handle_delay: bool = false,
    out_file: []const u8 = "",
};

fn get_next_arg_str(it: *std.process.ArgIterator) ![]const u8 {
    if (it.next()) |val| {
        return val;
    } else {
        return error.NotEnoughArgs;
    }
}

fn parse_args(a: std.mem.Allocator) !Args {
    var args_it = try std.process.argsWithAllocator(a);
    var args: Args = .{};

    args.progname = try get_next_arg_str(&args_it);
    args.num_requests = try std.fmt.parseInt(usize, try get_next_arg_str(&args_it), 10);
    args.base_url = try get_next_arg_str(&args_it);
    args.auth_bearer = try get_next_arg_str(&args_it);
    args.handle_delay = std.mem.eql(u8, try get_next_arg_str(&args_it), "true");
    args.out_file = try get_next_arg_str(&args_it);
    return args;
}

// here we go
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    var allocator = gpa.allocator();

    // parse args or show usage
    const args = parse_args(allocator) catch {
        try usage();
        std.os.exit(1);
    };
    std.debug.print("using args:\n  progname={s}\n  num_requests={d}\n  base_url={s}\n  auth_bearer={s}\n  handle_delay={}\n  out_file={s}\n", .{ args.progname, args.num_requests, args.base_url, args.auth_bearer, args.handle_delay, args.out_file });

    var transaction_log = TransactionLog.init(allocator);
    defer transaction_log.deinit();

    const url = "http://127.0.0.1:5500/api_guard/request_access?handle_delay=true";
    const auth_bearer = "Bearer renerocksai";
    const thread = try makeRequestThread(allocator, url, auth_bearer, &transaction_log);
    defer thread.join();
}
