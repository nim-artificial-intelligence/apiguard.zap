pub const RequestAccessResponse = struct {
    delay_ms: ?i64 = null,
    current_req_per_min: ?i64 = null,
    server_side_delay: ?i64 = null,
    my_time_ms: ?i64 = null,
    make_request_at_ms: ?i64 = null,
};

pub const SetRateLimitRequest = struct {
    new_limit: ?i64 = null,
};

pub const SetRateLimitResponse = struct {
    new_rate_limit: ?i64 = null,
    new_delay: ?i64 = null,
};

pub const GetRateLimitResponse = struct {
    success: bool,
    current_rate_limit: i64,
    delay_ms: i64,
};
