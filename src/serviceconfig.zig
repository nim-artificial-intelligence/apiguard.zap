const std = @import("std");

slug: []const u8,
port: usize,
initial_limit: i64,
initial_default_delay_ms: i64,
num_workers: i16,
api_token: []const u8,

const DEFAULT_SLUG = "/api_guard";
const DEFAULT_PORT: usize = 5500;
const DEFAULT_LIMIT: i64 = 500;
const DEFAULT_DELAY_MS: i64 = 30;
const DEFAULT_WORKERS: i16 = 8;

// TODO: security risk vs. convenience: should we allow a default token?
const DEFAULT_AUTH_TOKEN: []const u8 = "renerocksai";

pub fn init() @This() {
    return .{
        .slug = std.os.getenv("APIGUARD_SLUG") orelse "/api_guard",
        .port = parseEnvInt(usize, "port", "APIGUARD_PORT", DEFAULT_PORT),
        .initial_limit = parseEnvInt(i64, "API request limit", "APIGUARD_RATE_LIMIT", DEFAULT_LIMIT),
        .initial_default_delay_ms = parseEnvInt(i64, "API default delay", "APIGUARD_DELAY", DEFAULT_DELAY_MS),
        .num_workers = parseEnvInt(i16, "Number of worker threads", "APIGUARD_NUM_WORKERS", DEFAULT_WORKERS),

        .api_token = std.os.getenv("APIGUARD_AUTH_TOKEN") orelse "renerocksai",
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
