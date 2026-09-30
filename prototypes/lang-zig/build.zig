//! R-Type language POC, Zig edition: see README.md to build and run.
//!
//! ADR 0001 in Zig terms. Each part is a module, and a module can only
//! `@import` the modules this file adds to its import table (and files inside
//! its own directory). The imports are:
//!
//!   engine_headless  <-  game  <-  r-type_server
//!         ^               ^
//!   engine_client (raylib)   <-  r-type_client
//!
//! Zig accepts any import added here, though, even a wrong one such as the
//! Server importing engine_client. `checkLayering` at the bottom refuses
//! those, every time the build is configured.

const std = @import("std");
const Module = std.Build.Module;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Engine, headless part: nothing but the standard library.
    const engine_headless = b.createModule(.{
        .root_source_file = b.path("engine/headless/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Engine, client part: window, drawing, input and sound. raylib-zig builds
    // raylib 6.0 from source; its "raylib" module is the Zig binding, and
    // links the raylib library into whatever imports it.
    const raylib_zig = b.dependency("raylib_zig", .{ .target = target, .optimize = optimize });
    const raylib = raylib_zig.module("raylib");
    const engine_client = b.createModule(.{
        .root_source_file = b.path("engine/client/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "raylib", .module = raylib }},
    });

    // Game: messages and Match rules, on the headless Engine only.
    const game = b.createModule(.{
        .root_source_file = b.path("game/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "engine_headless", .module = engine_headless }},
    });

    const server = b.addExecutable(.{
        .name = "r-type_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "engine_headless", .module = engine_headless },
                .{ .name = "game", .module = game },
            },
        }),
    });
    b.installArtifact(server);

    const client = b.addExecutable(.{
        .name = "r-type_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "engine_headless", .module = engine_headless },
                .{ .name = "engine_client", .module = engine_client },
                .{ .name = "game", .module = game },
            },
        }),
    });
    // The sprite sheet is compiled into the program, so that it runs on its
    // own: client/sprites.zig reads it with @embedFile("ship_sheet").
    client.root_module.addAnonymousImport("ship_sheet", .{ .root_source_file = b.path("assets/r-typesheet42.gif") });
    b.installArtifact(client);

    // The fuzz test links the C library on every system, since it counts the
    // calls made to its allocation functions.
    const fuzz = b.addExecutable(.{
        .name = "protocol_fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/protocol_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "game", .module = game }},
        }),
    });
    b.installArtifact(fuzz);

    const run_fuzz = b.addRunArtifact(fuzz);
    if (b.args) |args| run_fuzz.addArgs(args);
    b.step("fuzz", "Run the protocol fuzz test (zig build fuzz -- <datagrams> <seed>)").dependOn(&run_fuzz.step);

    for ([_]struct { []const u8, *std.Build.Step.Compile }{ .{ "server", server }, .{ "client", client } }) |program| {
        const run = b.addRunArtifact(program[1]);
        if (b.args) |args| run.addArgs(args);
        b.step(program[0], b.fmt("Run {s} (arguments after --)", .{program[1].name})).dependOn(&run.step);
    }

    const unit_tests = b.step("test", "Run the unit tests");
    for ([_]*Module{ engine_headless, game, engine_client }) |module| {
        unit_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }

    checkLayering(&.{
        .{ .module = raylib, .importers = &.{engine_client}, .why = "raylib stays behind the Engine's client part" },
        .{ .module = engine_client, .importers = &.{client.root_module}, .why = "only the Client program draws: the Server and the Game stay headless" },
        .{ .module = game, .importers = &.{ server.root_module, client.root_module, fuzz.root_module }, .why = "the Engine knows nothing about the Game" },
    }, &.{ server.root_module, client.root_module, fuzz.root_module });
}

/// A module, and the only modules that may import it.
const Rule = struct {
    module: *Module,
    importers: []const *Module,
    why: []const u8,
};

/// Follows the imports of every module the programs reach, and stops the
/// build at the first one that breaks a rule. It runs when the build is
/// configured, before anything is compiled.
fn checkLayering(rules: []const Rule, programs: []const *Module) void {
    var reached: [64]*Module = undefined;
    @memcpy(reached[0..programs.len], programs);
    var count = programs.len;
    var next: usize = 0;
    while (next < count) : (next += 1) {
        const importer = reached[next];
        for (importer.import_table.keys(), importer.import_table.values()) |name, imported| {
            for (rules) |rule| {
                if (imported != rule.module) continue;
                if (std.mem.findScalar(*Module, rule.importers, importer) != null) continue;
                std.process.fatal("ADR 0001: {s} may not import \"{s}\": {s}", .{
                    importer.root_source_file.?.getDisplayName(), name, rule.why,
                });
            }
            if (std.mem.findScalar(*Module, reached[0..count], imported) == null) {
                reached[count] = imported;
                count += 1;
            }
        }
    }
}
