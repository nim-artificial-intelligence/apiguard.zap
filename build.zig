const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});

    // we always build for musl
    target.abi = .musl;

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "apiguard",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const zap = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("zap", zap.module("zap"));
    exe.linkLibrary(zap.artifact("facil.io"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // -----------------------------------------------------------------------
    // clientbot
    // -----------------------------------------------------------------------

    const clientbot = b.addExecutable(.{
        .name = "clientbot",
        .root_source_file = .{ .path = "src/clientbot.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(clientbot);
}
