const std = @import("std");
const zap = @import("zap");
const ApiEndpoint = @import("api_endpoint.zig");
const ServiceConfig = @import("serviceconfig.zig");

const is_debug_build = @import("builtin").mode == std.builtin.Mode.Debug;

// issue a 404 by default
fn on_default_request(r: zap.SimpleRequest) void {
    r.setStatus(.not_found);
    r.sendJson("{ \"status\": \"not found\"}") catch |err| {
        std.log.err("could not send 404 response: {any}\n", .{err});
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

    const config = ServiceConfig.init();

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
        \\ USING NUM WORKERS  : {d}
        \\
        \\
    , .{ config.port, config.slug, config.api_token, config.initial_limit, config.initial_default_delay_ms, config.num_workers });

    var listener = zap.SimpleEndpointListener.init(allocator, .{
        .port = config.port,
        .on_request = on_default_request,
        .max_clients = 1000,
        .max_body_size = 1024, // 1kB for incoming JSON is more than enough
        .log = true,
    });

    // Serves a JSON API
    //
    var api_endpoint = ApiEndpoint.init(allocator, config.slug, config.initial_limit, config.initial_default_delay_ms);

    // create authenticator
    const Authenticator = zap.BearerAuthSingle;
    var authenticator = try Authenticator.init(allocator, config.api_token, null);
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
        // yes, we call them workers here for simplicity
        .threads = config.num_workers,

        // IMPORTANT!
        //
        // It is crucial to only have a single worker for this example to work!
        // Multiple workers would have multiple copies of the timing struct
        //
        // Since zap is quite fast, you can do A LOT with a single worker.
        // Try it with `zig build -Doptimize=ReleaseFast`
        .workers = 1,
    });
    std.debug.print("\n\nAll worker threads stopped\n", .{});
}
