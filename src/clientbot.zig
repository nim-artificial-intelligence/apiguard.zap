const std = @import("std");
const ServiceConfig = @import("serviceconfig.zig");
const Api = @import("api.zig");

const ClientRequest = struct {
    uri: std.Uri,
    handle_delay: bool,
};

const Transaction = struct {
    sequence_number: usize,
    thread_id: usize,
    thread_sequence_number: usize,
    request_timestamp_ms: isize,
    request: ClientRequest,
    response_timestamp_ms: ?isize = null,
    response: ?Api.RequestAccessResponse = null,
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

    pub fn newTransaction(self: *Self, url: []const u8, thread_id: usize, thread_sequence_number: usize) !Transaction {
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
            .thread_id = thread_id,
            .thread_sequence_number = thread_sequence_number,
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

fn makeRequests(a: std.mem.Allocator, thread_id: usize, howmany: usize, url: []const u8, auth_bearer: []const u8, transaction_log: *TransactionLog) !void {
    var thread_sequence_number: usize = 0;

    var h = std.http.Headers{ .allocator = a };
    defer h.deinit();
    try h.append("Authorization", auth_bearer);

    while (thread_sequence_number < howmany) : (thread_sequence_number += 1) {
        var transaction = try transaction_log.newTransaction(url, thread_id, thread_sequence_number);

        var http_client: std.http.Client = .{ .allocator = a };
        defer http_client.deinit();

        var req = try http_client.request(.GET, transaction.request.uri, h, .{});
        defer req.deinit();

        try req.start();
        try req.wait();

        var buffer: [1024]u8 = undefined;
        const rsize = try req.readAll(&buffer);
        transaction.response_timestamp_ms = std.time.milliTimestamp();

        const parsed = try std.json.parseFromSlice(Api.RequestAccessResponse, a, buffer[0..rsize], .{});
        defer parsed.deinit();
        transaction.response = parsed.value;

        try transaction_log.addTransaction(transaction);
    }
}

fn makeRequestThread(a: std.mem.Allocator, thread_id: usize, howmany: usize, url: []const u8, auth_bearer: []const u8, tlog: *TransactionLog) !std.Thread {
    return try std.Thread.spawn(.{}, makeRequests, .{ a, thread_id, howmany, url, auth_bearer, tlog });
}

pub fn usage() !void {
    const stdout = std.io.getStdOut().writer();
    const progname = "clientbot";
    try stdout.print("Usage: {s} num-threads requests-per-thread handle_delay outfile\n", .{progname});
}

const Args = struct {
    progname: []const u8 = "clientbot",
    num_threads: usize = 0,
    handle_delay: bool = true,
    num_req_per_thread: usize = 0,
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
    args.num_threads = try std.fmt.parseInt(usize, try get_next_arg_str(&args_it), 10);
    args.num_req_per_thread = try std.fmt.parseInt(usize, try get_next_arg_str(&args_it), 10);
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
    const stderr = std.io.getStdErr().writer();

    // parse args or show usage
    const args = parse_args(allocator) catch {
        try usage();
        std.os.exit(1);
    };
    const scfg = ServiceConfig.init();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}/request_access?handle_delay={}", .{ scfg.port, scfg.slug, args.handle_delay });
    defer allocator.free(url);
    try stderr.print(
        \\Using args:
        \\    progname        : {s}
        \\    num_threads     : {d}
        \\    req_per_thread  : {d}
        \\    url             : {s}
        \\    auth_bearer     : {s}
        \\    out_file        : {s}
        \\
        \\
    , .{ args.progname, args.num_threads, args.num_req_per_thread, url, scfg.api_token, args.out_file });

    var transaction_log = TransactionLog.init(allocator);
    defer transaction_log.deinit();

    const auth_bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{scfg.api_token});
    defer allocator.free(auth_bearer);

    var threads = std.ArrayList(std.Thread).init(allocator);
    for (0..args.num_threads) |i| {
        const thread = try makeRequestThread(allocator, i, args.num_req_per_thread, url, auth_bearer, &transaction_log);
        threads.append(thread) catch break;
    }

    while (true) {
        const progress = blk: {
            transaction_log.transaction_lock.lock();
            defer transaction_log.transaction_lock.unlock();
            break :blk transaction_log._current_sequence_number;
        };
        const limit = args.num_req_per_thread * args.num_threads;
        try stderr.print("Progress: {d:6} / {d:6}\r", .{ progress, limit });
        if (progress == limit) {
            try stderr.print("Progress: {d:6} / {d:6}\n", .{ progress, limit });
            break;
        }
        std.time.sleep(200 * std.time.ns_per_ms);
    }
    for (threads.items) |t| {
        t.join();
    }

    try saveTransactionLog(args, &transaction_log, url, args.out_file);
}

fn saveTransactionLog(args: Args, transaction_log: *TransactionLog, url: []const u8, filename: []const u8) !void {
    const scfg = ServiceConfig.init();

    var f = try std.fs.cwd().createFile(filename, .{});
    defer f.close();
    var writer = f.writer();
    try writer.print(
        \\{{
        \\   "apiguard_config": {{
        \\       "slug": "{s}",
        \\       "port": {d},
        \\       "initial_limit": {d},
        \\       "num_workers": {d},
        \\       "api_token": "{s}"
        \\   }},
        \\
    , .{
        scfg.slug,
        scfg.port,
        scfg.initial_limit,
        scfg.num_workers,
        scfg.api_token,
    });

    try writer.print(
        \\   "config" : {{
        \\      "num_threads": {d},
        \\      "req_per_thread": {d},
        \\      "url": "{s}",
        \\      "auth_bearer": "{s}",
        \\      "out_file": "{s}"
        \\   }},
        \\   "transactions" : [
        \\
    , .{
        args.num_threads,
        args.num_req_per_thread,
        url,
        scfg.api_token,
        args.out_file,
    });

    const num_transactions = transaction_log.transactions.items.len;
    for (transaction_log.transactions.items, 0..) |t, i| {
        const separator = if (i < num_transactions - 1) "," else "";
        const response: Api.RequestAccessResponse = t.response orelse .{};
        try writer.print(
            \\     {{
            \\        "sequence_number": {d},
            \\        "thread_id": {d},
            \\        "thread_sequence_number": {d},
            \\        "request_timestamp_ms": {d},
            \\        "response_timestamp_ms": {?},
            \\        "request": {{
            \\            "url": "{s}",
            \\            "handle_delay": {}
            \\        }},
            \\        "response": {{
            \\            "delay_ms": {?},
            \\            "current_req_per_min": {?},
            \\            "server_side_delay": {?},
            \\            "my_time_ms": {?},
            \\            "make_request_at_ms": {?}
            \\        }}
            \\     }}{s}
            \\
        ,
            .{ t.sequence_number, t.thread_id, t.thread_sequence_number, t.request_timestamp_ms, t.response_timestamp_ms, url, t.request.handle_delay, response.delay_ms, response.current_req_per_min, response.server_side_delay, response.my_time_ms, response.make_request_at_ms, separator },
        );
    }
    try writer.print(
        \\   ]
        \\}}
        \\
    , .{});
}
