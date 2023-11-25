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
    thread_id: usize,
    thread_sequence_number: usize,
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

        const parsed = try std.json.parseFromSlice(ServerResponse, a, buffer[0..rsize], .{});
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
    try stdout.print("Usage: {s} num-threads equests-per-thread url auth-token outfile\n", .{progname});
}

const Args = struct {
    progname: []const u8 = "clientbot",
    num_threads: usize = 0,
    num_req_per_thread: usize = 0,
    url: []const u8 = "",
    auth_bearer: []const u8 = "",
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
    args.url = try get_next_arg_str(&args_it);
    args.auth_bearer = try get_next_arg_str(&args_it);
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
    std.debug.print(
        \\Using args:
        \\    progname        : {s}
        \\    num_threads     : {d}
        \\    req_per_thread  : {d}
        \\    url             : {s}
        \\    auth_bearer     : {s}
        \\    out_file        : {s}
        \\
        \\
    , .{ args.progname, args.num_threads, args.num_req_per_thread, args.url, args.auth_bearer, args.out_file });

    var transaction_log = TransactionLog.init(allocator);
    defer transaction_log.deinit();

    const auth_bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{args.auth_bearer});
    defer allocator.free(auth_bearer);

    var threads = std.ArrayList(std.Thread).init(allocator);
    for (0..args.num_threads) |i| {
        const thread = try makeRequestThread(allocator, i, args.num_req_per_thread, args.url, auth_bearer, &transaction_log);
        threads.append(thread) catch break;
    }

    while (true) {
        const progress = blk: {
            transaction_log.transaction_lock.lock();
            defer transaction_log.transaction_lock.unlock();
            break :blk transaction_log._current_sequence_number;
        };
        const limit = args.num_req_per_thread * args.num_threads;
        std.debug.print("Progress: {d:6} / {d:6}\r", .{ progress, limit });
        if (progress == limit) {
            std.debug.print("Progress: {d:6} / {d:6}\n", .{ progress, limit });
            break;
        }
        std.time.sleep(200 * std.time.ns_per_ms);
    }
    for (threads.items) |t| {
        t.join();
    }

    // now print the transaction log
    for (transaction_log.transactions.items) |transaction| {
        std.debug.print("{}\n", .{transaction});
    }
    try saveTransactionLog(args, &transaction_log, args.out_file);
}

fn saveTransactionLog(args: Args, transaction_log: *TransactionLog, filename: []const u8) !void {
    var f = try std.fs.cwd().createFile(filename, .{});
    defer f.close();
    var writer = f.writer();
    try writer.print(
        \\{{
        \\   "config" : {{
        \\      "num_threads": {d},
        \\      "req_per_thread": {d},
        \\      "url": "{s}",
        \\      "auth_bearer": "{s}",
        \\      "out_file": "{s}"
        \\   }},
        \\   "transactions" : [
        \\
    , .{ args.num_threads, args.num_req_per_thread, args.url, args.auth_bearer, args.out_file });
    const num_transactions = transaction_log.transactions.items.len;
    for (transaction_log.transactions.items) |t| {
        const separator = if (t.sequence_number < num_transactions) "," else "";
        const OptResponse = struct { delay_ms: ?usize = null, current_req_per_min: ?usize = null, server_side_delay: ?usize = null };
        const response: OptResponse = blk: {
            if (t.response) |r| {
                break :blk .{
                    .delay_ms = r.delay_ms,
                    .current_req_per_min = r.current_req_per_min,
                    .server_side_delay = r.server_side_delay,
                };
            } else {
                break :blk .{};
            }
        };
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
            \\            "server_side_delay": {?}
            \\        }}
            \\     }}{s}
            \\
        ,
            .{ t.sequence_number, t.thread_id, t.thread_sequence_number, t.request_timestamp_ms, t.response_timestamp_ms, args.url, t.request.handle_delay, response.delay_ms, response.current_req_per_min, response.server_side_delay, separator },
        );
    }
    try writer.print(
        \\   ]
        \\}}
        \\
    , .{});
}
