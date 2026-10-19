//! A settings file the player can edit: ZON, so it takes `//` comments, read
//! into whatever `Settings` type the program declares. Like all of the Engine,
//! it knows nothing about what the settings mean.
//!
//! For an application named `app` and a file named `name`, `load` uses the
//! first of these that it can read:
//! 1. `name` next to the executable, which overrides the other file entirely;
//! 2. `name` in the operating system's config folder: `$XDG_CONFIG_HOME/app`
//!    (`~/.config/app` without it) on Linux and other Unix systems,
//!    `%APPDATA%\app` on Windows, `~/Library/Application Support/app` on macOS;
//! 3. `Settings{}`, the defaults.
//!
//! A file that is missing is skipped silently. A file that cannot be read or
//! is not valid is skipped with a warning naming what is wrong: loading never
//! fails. When the config folder has no `name`, the program's commented
//! defaults are written there, for the player to find and edit.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.settings);

/// Larger files are refused: a settings file is a few kilobytes.
pub const max_file_size = 64 * 1024;

pub const Files = struct {
    /// The folder created in the config folder, such as "r-type".
    app: []const u8,
    /// The file's name, in both places, such as "settings.zon".
    name: []const u8,
    /// What is written to the config folder when the file is missing there:
    /// `Settings{}` as ZON, with comments explaining each setting.
    defaults: []const u8,
};

/// Reads the settings as described at the top of this file. Everything,
/// including the returned settings, is allocated in `arena`.
pub fn load(
    comptime Settings: type,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    files: Files,
) Settings {
    const config_dir = configDir(arena, environ, builtin.os.tag, files.app);
    if (config_dir == null) log.warn("no config folder: neither HOME nor APPDATA is set", .{});
    const exe_dir = std.process.executableDirPathAlloc(io, arena) catch |err| no_dir: {
        log.warn("cannot find the executable's folder ({t}); not looking for a {s} there", .{ err, files.name });
        break :no_dir null;
    };
    const override = if (exe_dir) |dir| join(arena, &.{ dir, files.name }) else null;
    return loadFrom(Settings, arena, io, override, config_dir, files);
}

/// `load`, with the two folders given: `override` is the full path of the
/// file next to the executable, and `config_dir` the config folder.
fn loadFrom(
    comptime Settings: type,
    arena: Allocator,
    io: Io,
    override: ?[]const u8,
    config_dir: ?[]const u8,
    files: Files,
) Settings {
    const config = if (config_dir) |dir| join(arena, &.{ dir, files.name }) else null;
    if (config_dir) |dir| writeDefaultsIfMissing(io, dir, config.?, files.defaults);
    if (override) |path| {
        if (parseFile(Settings, arena, io, path)) |settings| return settings;
    }
    if (config) |path| {
        if (parseFile(Settings, arena, io, path)) |settings| return settings;
    }
    return .{};
}

/// The settings in `path`, or null if there is no such file or it is not
/// valid, with a warning in the latter case.
fn parseFile(comptime Settings: type, arena: Allocator, io: Io, path: []const u8) ?Settings {
    const source = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(max_file_size), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            log.warn("cannot read {s} ({t}); ignoring it", .{ path, err });
            return null;
        },
    };
    var diagnostics: std.zon.parse.Diagnostics = .{};
    const settings = std.zon.parse.fromSliceAlloc(Settings, arena, source, &diagnostics, .{ .free_on_error = false }) catch |err| {
        switch (err) {
            error.OutOfMemory => log.warn("no memory left to read {s}; ignoring it", .{path}),
            error.ParseZon => log.warn("{s} is not valid; ignoring it:\n{f}", .{ path, diagnostics }),
        }
        return null;
    };
    log.info("read {s}", .{path});
    return settings;
}

/// Writes `defaults` to `path`, in `dir`, unless a file is already there.
/// Never overwrites, even a file that is not valid: it is the player's.
fn writeDefaultsIfMissing(io: Io, dir: []const u8, path: []const u8, defaults: []const u8) void {
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch |err| {
        log.warn("cannot create {s} ({t}); not writing the default settings", .{ dir, err });
        return;
    };
    cwd.writeFile(io, .{ .sub_path = path, .data = defaults, .flags = .{ .exclusive = true } }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => {
            log.warn("cannot write the default settings to {s} ({t})", .{ path, err });
            return;
        },
    };
    log.info("wrote the default settings to {s}", .{path});
}

/// The config folder of `app` on `os`, from the environment; null if the
/// variables it depends on are not set.
fn configDir(arena: Allocator, environ: *const std.process.Environ.Map, os: std.Target.Os.Tag, app: []const u8) ?[]const u8 {
    switch (os) {
        .windows => {
            const app_data = nonEmpty(environ.get("APPDATA")) orelse return null;
            return join(arena, &.{ app_data, app });
        },
        .macos => {
            const home = nonEmpty(environ.get("HOME")) orelse return null;
            return join(arena, &.{ home, "Library", "Application Support", app });
        },
        else => {
            // The XDG Base Directory specification ignores a relative path.
            if (nonEmpty(environ.get("XDG_CONFIG_HOME"))) |config_home| {
                if (std.fs.path.isAbsolutePosix(config_home)) return join(arena, &.{ config_home, app });
            }
            const home = nonEmpty(environ.get("HOME")) orelse return null;
            return join(arena, &.{ home, ".config", app });
        },
    }
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const string = value orelse return null;
    return if (string.len == 0) null else string;
}

/// Joins path components, or returns null when out of memory: the settings
/// then fall back to what does not need that path.
fn join(arena: Allocator, parts: []const []const u8) ?[]const u8 {
    return std.fs.path.join(arena, parts) catch null;
}

const testing = std.testing;

const TestSettings = struct {
    volume: u8 = 5,
    name: []const u8 = "default",
};

const test_defaults =
    \\// The defaults, with a comment.
    \\.{ .volume = 5, .name = "default" }
    \\
;

/// A temporary folder, and the paths `loadFrom` sees in it.
const Scratch = struct {
    tmp: testing.TmpDir,
    root: []const u8,
    override: []const u8,
    config_dir: []const u8,
    config: []const u8,

    fn init(arena: Allocator) !Scratch {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
        return .{
            .tmp = tmp,
            .root = root,
            .override = try std.fs.path.join(arena, &.{ root, "settings.zon" }),
            .config_dir = try std.fs.path.join(arena, &.{ root, "config", "app" }),
            .config = try std.fs.path.join(arena, &.{ root, "config", "app", "settings.zon" }),
        };
    }

    fn load(s: *Scratch, arena: Allocator) TestSettings {
        return loadFrom(TestSettings, arena, testing.io, s.override, s.config_dir, .{
            .app = "app",
            .name = "settings.zon",
            .defaults = test_defaults,
        });
    }
};

fn writeTestFile(path: []const u8, data: []const u8) !void {
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data });
}

fn readTestFile(arena: Allocator, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(max_file_size));
}

test "with no file anywhere, the defaults are used and written to the config folder" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s: Scratch = try .init(arena);
    defer s.tmp.cleanup();

    try testing.expectEqualDeep(TestSettings{}, s.load(arena));
    try testing.expectEqualStrings(test_defaults, try readTestFile(arena, s.config));
}

test "the file next to the executable overrides the config folder's" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s: Scratch = try .init(arena);
    defer s.tmp.cleanup();

    try s.tmp.dir.createDirPath(testing.io, "config/app");
    try writeTestFile(s.config, ".{ .volume = 1 }");
    try testing.expectEqualDeep(TestSettings{ .volume = 1 }, s.load(arena));
    // Entirely: a setting the override leaves out takes its default, not the config file's.
    try writeTestFile(s.override, ".{ .name = \"override\" }");
    try testing.expectEqualDeep(TestSettings{ .name = "override" }, s.load(arena));
}

test "an invalid file is skipped, never overwritten, and never fatal" {
    // The warnings are expected here: keep them out of the test output.
    const log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = log_level;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s: Scratch = try .init(arena);
    defer s.tmp.cleanup();

    try s.tmp.dir.createDirPath(testing.io, "config/app");
    try writeTestFile(s.config, ".{ .volume = 2 }");
    try writeTestFile(s.override, ".{ .volume = 300 }"); // out of range for a u8
    try testing.expectEqualDeep(TestSettings{ .volume = 2 }, s.load(arena));

    const broken = ".{ .volum = 3 }"; // a typo: unknown field
    try writeTestFile(s.config, broken);
    try writeTestFile(s.override, "not zon at all");
    try testing.expectEqualDeep(TestSettings{}, s.load(arena));
    try testing.expectEqualStrings(broken, try readTestFile(arena, s.config));
}

test "the config folder follows each system's convention" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ: std.process.Environ.Map = .init(arena);
    try testing.expectEqual(null, configDir(arena, &environ, .linux, "app"));

    try environ.put("HOME", "/home/p");
    try environ.put("APPDATA", "C:\\Users\\p\\AppData\\Roaming");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ "/home/p", ".config", "app" }), configDir(arena, &environ, .linux, "app").?);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ "/home/p", "Library", "Application Support", "app" }), configDir(arena, &environ, .macos, "app").?);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ "C:\\Users\\p\\AppData\\Roaming", "app" }), configDir(arena, &environ, .windows, "app").?);

    try environ.put("XDG_CONFIG_HOME", "relative/is/ignored");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ "/home/p", ".config", "app" }), configDir(arena, &environ, .linux, "app").?);
    try environ.put("XDG_CONFIG_HOME", "/xdg");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ "/xdg", "app" }), configDir(arena, &environ, .freebsd, "app").?);
}
