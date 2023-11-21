const std = @import("std");
const zap = @import("zap");
const ApiEndpoint = @import("api_endpoint.zig");

const is_debug_build = @import("builtin").mode == std.builtin.Mode.Debug;

// const FRONTEND_SLUG = "/frontend";
const DEFAULT_SLUG = "/apiguard";
const DEFAULT_PORT: usize = 5501;
const DEFAULT_LIMIT: usize = 500;
const DEFAULT_DELAY_MS: usize = 30;
const DEFAULT_AUTH_TOKEN: []const u8 = "renerocksai";

// issue a 404 by default
fn on_default_request(r: zap.SimpleRequest) void {
    r.setStatus(.not_found);
    r.sendJson("{ \"status\": \"not found\"}") catch |err| {
        std.log.err("could not send 404 response: {any}\n", .{err});
    };
}

fn parseEnvInt(comptime T: type, what: []const u8, from_env_var: []const u8, default: T) T {
    return blk: {
        if (std.os.getenv(from_env_var)) |value_str| {
            const value = std.fmt.parseInt(T, value_str, 10) catch |err| {
                std.log.err("Error: could not parse {s} from {s}: `{s}`: {any}", .{ what, from_env_var, value_str, err });
                std.os.exit(1);
            };
            break :blk value;
        } else {
            break :blk default;
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    var allocator = gpa.allocator();

    if (is_debug_build) {
        zap.Log.fio_set_log_level(zap.Log.fio_log_level_debug);
    }

    const slug = std.os.getenv("APIGUARD_SLUG") orelse "/apiguard";
    const port = parseEnvInt(usize, "port", "APIGUARD_PORT", DEFAULT_PORT);
    const initial_limit = parseEnvInt(usize, "API request limit", "APIGUARD_LIMIT", DEFAULT_LIMIT);
    const initial_default_delay_ms = parseEnvInt(usize, "API default delay", "APIGUARD_DELAY", DEFAULT_DELAY_MS);
    const api_token = std.os.getenv("APIGUARD_AUTH_TOKEN") orelse "renerocksai";

    std.debug.print(
        \\
        \\
        \\
        \\ ======================================================
        \\ ===   Visit me on http://127.0.0.1:{d}{s}   ===
        \\ ======================================================
        \\
        \\ USING API TOKEN    : {s}
        \\ USING API LIMIT    : {d}
        \\ USING API DELAY    : {d} ms
        \\
        \\
    , .{ port, slug, api_token, initial_limit, initial_default_delay_ms });

    var listener = zap.SimpleEndpointListener.init(allocator, .{
        .port = port,
        .on_request = on_default_request,
        .max_clients = 1000,
        .max_body_size = 1024, // 1kB for incoming JSON is more than enough
        .log = true,
    });

    // Serves a JSON API
    //
    var api_endpoint = ApiEndpoint.init(allocator, slug);

    // create authenticator
    const Authenticator = zap.BearerAuthSingle;
    var authenticator = try Authenticator.init(allocator, api_token, null);
    defer authenticator.deinit();

    // create authenticating endpoint
    const BearerAuthEndpoint = zap.AuthenticatingEndpoint(Authenticator);
    var auth_ep = BearerAuthEndpoint.init(api_endpoint.getEndpoint(), &authenticator);

    try listener.addEndpoint(auth_ep.getEndpoint());

    // and GO!
    try listener.listen();
    if (is_debug_build) {
        zap.enableDebugLog();
    }

    // start worker threads
    zap.start(.{
        .threads = 8,

        // IMPORTANT!
        //
        // It is crucial to only have a single worker for this example to work!
        // Multiple workers would have multiple copies of the timing struct
        //
        // Since zap is quite fast, you can do A LOT with a single worker.
        // Try it with `zig build -Doptimize=ReleaseFast`
        .workers = 1,
    });
    std.debug.print("\n\nThreads stopped\n", .{});
}
