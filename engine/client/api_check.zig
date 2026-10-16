//! A compile-time check that a module's public API exposes no type from a
//! module it keeps hidden, for ADR 0001: raylib stays behind the Engine's
//! client part.
//!
//! Zig names a type after the file that declares it, not after its module:
//! raylib-zig's texture type is `raylib.Texture` because it lives in the file
//! raylib.zig, and its rlgl types are `rlgl.…`. The check is therefore given
//! the file names of the hidden module, and refuses every type whose name
//! mentions one of them, also as the argument of a generic type, as in
//! `array_list.Aligned(raylib.Texture,null)`.
//!
//! It starts from every public declaration and follows the types they
//! mention: struct and union fields (all public in Zig), function parameters
//! and results, and pointer, array, optional and error union payloads. It
//! walks the public declarations of this module's own types only.

const std = @import("std");

pub fn refuseTypesFrom(comptime hidden_files: []const []const u8, comptime Api: type) void {
    @setEvalBranchQuota(100_000);
    _ = visit(hidden_files, @typeName(Api), Api, @typeName(Api), &.{});
}

fn visit(
    comptime hidden_files: []const []const u8,
    comptime own: []const u8,
    comptime T: type,
    comptime where: []const u8,
    comptime seen: []const type,
) []const type {
    for (seen) |known| if (known == T) return seen;
    const name = @typeName(T);
    for (hidden_files) |file| {
        if (mentions(name, file)) {
            @compileError(where ++ " exposes " ++ name ++ ", from " ++ file ++ ".zig, which this module keeps hidden");
        }
    }
    var now: []const type = seen ++ [_]type{T};
    const is_own = std.mem.eql(u8, name, own) or std.mem.startsWith(u8, name, own ++ ".");
    switch (@typeInfo(T)) {
        .pointer => |info| now = visit(hidden_files, own, info.child, where, now),
        .array => |info| now = visit(hidden_files, own, info.child, where, now),
        .optional => |info| now = visit(hidden_files, own, info.child, where, now),
        .error_union => |info| now = visit(hidden_files, own, info.payload, where, now),
        .@"fn" => |info| {
            for (info.params) |param| {
                if (param.type) |Param| now = visit(hidden_files, own, Param, where, now);
            }
            if (info.return_type) |Result| now = visit(hidden_files, own, Result, where, now);
        },
        .@"struct" => |info| if (is_own) {
            for (info.fields) |field| now = visit(hidden_files, own, field.type, name ++ "." ++ field.name, now);
            now = visitDecls(hidden_files, own, T, info.decls, now);
        },
        .@"union" => |info| if (is_own) {
            for (info.fields) |field| now = visit(hidden_files, own, field.type, name ++ "." ++ field.name, now);
            now = visitDecls(hidden_files, own, T, info.decls, now);
        },
        .@"enum" => |info| if (is_own) {
            now = visitDecls(hidden_files, own, T, info.decls, now);
        },
        .@"opaque" => |info| if (is_own) {
            now = visitDecls(hidden_files, own, T, info.decls, now);
        },
        else => {},
    }
    return now;
}

/// Public declarations only: `@typeInfo` lists no others.
fn visitDecls(
    comptime hidden_files: []const []const u8,
    comptime own: []const u8,
    comptime T: type,
    comptime decls: []const std.builtin.Type.Declaration,
    comptime seen: []const type,
) []const type {
    var now = seen;
    for (decls) |decl| {
        const value = @field(T, decl.name);
        const where = @typeName(T) ++ "." ++ decl.name;
        const Declared = if (@TypeOf(value) == type) value else @TypeOf(value);
        now = visit(hidden_files, own, Declared, where, now);
    }
    return now;
}

/// True if `name` contains `file` as a whole component: at the start or after
/// a character that cannot be part of a file name, and followed by a dot (a
/// declaration of that file) or by the end.
fn mentions(name: []const u8, file: []const u8) bool {
    var start: usize = 0;
    while (std.mem.findPos(u8, name, start, file)) |at| : (start = at + 1) {
        const end = at + file.len;
        const starts_component = at == 0 or !isFileNameChar(name[at - 1]);
        const ends_component = end == name.len or name[end] == '.';
        if (starts_component and ends_component) return true;
    }
    return false;
}

fn isFileNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}
