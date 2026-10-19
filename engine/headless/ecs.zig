//! A minimal entity-component-system (ADR 0003), stored as one fixed-capacity
//! table per kind of entity (ADR 0006). Nothing is ever allocated: a table is
//! one plain value, held inline.
//!
//! The Engine knows nothing about the components. Each program declares a
//! World, a struct whose fields are all tables, and each table's `Row` lists the
//! components of one kind of entity:
//!
//!     const World = struct {
//!         ships: ecs.Table(4, struct { player: u8, position: Vec2 }),
//!         projectiles: ecs.Table(32, struct { position: Vec2, velocity: Vec2 }),
//!     };
//!     var world: World = .{ .ships = .empty, .projectiles = .empty };
//!
//!     _ = world.projectiles.spawn(.{ .position = p, .velocity = v }); // null: the table is full
//!
//!     for (ecs.query(&world, .{ .position, .velocity })) |rows| {
//!         for (rows.position, rows.velocity) |*position, velocity| position.* = position.plus(velocity);
//!     }
//!
//!     world.projectiles.removeIf({}, offScreen); // a step of its own, after the systems
//!
//! An entity keeps the components it spawned with and never changes table. A
//! spawn takes effect at once, and rows leave a table only through `removeIf`,
//! so nothing is ever deferred.
//!
//! Rows stay in spawn order, and ids are handed out in a fixed sequence, so the
//! same calls always give the same world: a Match with a seeded generator can
//! be replayed in tests.

const std = @import("std");

/// Names one entity among the live rows of its table; a program tells entities
/// apart by table and id. A table hands ids out from a wrapping counter that
/// skips the ones in use, so an id comes back only after at least 256 minus
/// the table's capacity other spawns in that table. Ids exist for Snapshots: a
/// Tick never needs to keep one.
pub const Id = u8;

/// The entities of one kind: one array per field of `Row_`, live rows packed
/// at the front, at most `capacity_` of them, from 1 to 256.
pub fn Table(comptime capacity_: usize, comptime Row_: type) type {
    if (capacity_ == 0 or capacity_ > 256) @compileError("a table holds 1 to 256 rows");
    const fields = @typeInfo(Row_).@"struct".fields;
    if (@hasField(Row_, "ids")) @compileError("\"ids\" is reserved for the ids in query results");

    return struct {
        const Self = @This();

        pub const capacity = capacity_;
        pub const Row = Row_;
        /// One name per component, the fields of `Row`.
        pub const Component = std.meta.FieldEnum(Row);

        /// One array per component, indexed by row.
        const Columns = columns: {
            var names: [fields.len][:0]const u8 = undefined;
            var types: [fields.len]type = undefined;
            for (fields, &names, &types) |field, *name, *T| {
                name.* = field.name;
                T.* = [capacity]field.type;
            }
            break :columns @Struct(.auto, null, &names, &types, &@splat(.{}));
        };

        /// Meaningful in rows `0..len` only.
        columns: Columns,
        /// Meaningful in rows `0..len` only.
        ids: [capacity]Id,
        /// Live rows. Zig has no private fields: only this type's functions
        /// change it.
        len: usize,
        /// The ids of the live rows.
        in_use: std.StaticBitSet(256),
        /// Where the search for the next free id starts.
        next_id: Id,
        /// Spawns refused because the table was full, for the program to log.
        dropped: u32,

        pub const empty: Self = .{
            .columns = undefined,
            .ids = undefined,
            .len = 0,
            .in_use = .empty,
            .next_id = 0,
            .dropped = 0,
        };

        /// Adds a row at once and returns its id; null, and counted in
        /// `dropped`, when the table is full. Safe inside a loop over any
        /// table: storage never moves, and the loop does not see the new row.
        pub fn spawn(t: *Self, row: Row) ?Id {
            if (t.len == capacity) {
                t.dropped +|= 1;
                return null;
            }
            // Fewer than 256 ids are in use, so the search ends.
            var id = t.next_id;
            while (t.in_use.isSet(id)) id +%= 1;
            t.in_use.set(id);
            t.next_id = id +% 1;

            inline for (fields) |field| @field(t.columns, field.name)[t.len] = @field(row, field.name);
            t.ids[t.len] = id;
            t.len += 1;
            return id;
        }

        /// How many more rows fit, so that a group of entities can be spawned
        /// whole or not at all.
        pub fn free(t: *const Self) usize {
            return capacity - t.len;
        }

        /// One component of every live row, in row order: zip several in one
        /// `for`. Valid until the next `removeIf` on this table.
        pub fn items(t: *Self, comptime component: Component) []@FieldType(Row, @tagName(component)) {
            return @field(t.columns, @tagName(component))[0..t.len];
        }

        /// The id of every live row, in row order.
        pub fn liveIds(t: *const Self) []const Id {
            return t.ids[0..t.len];
        }

        /// Removes every row for which `remove(context, id, row)` returns true,
        /// keeping the others in order, and frees their ids. It is the only way
        /// to remove rows, and it must never run inside a loop over the same
        /// table.
        pub fn removeIf(t: *Self, context: anytype, comptime remove: anytype) void {
            var kept: usize = 0;
            for (0..t.len) |i| {
                var row: Row = undefined;
                inline for (fields) |field| @field(row, field.name) = @field(t.columns, field.name)[i];
                if (remove(context, t.ids[i], row)) {
                    t.in_use.unset(t.ids[i]);
                    continue;
                }
                inline for (fields) |field| @field(t.columns, field.name)[kept] = @field(row, field.name);
                t.ids[kept] = t.ids[i];
                kept += 1;
            }
            t.len = kept;
        }
    };
}

/// For each table of `world.*` (a struct whose fields are all tables) that has
/// every component in `wanted`, a tuple of enum literals: that table's `ids`,
/// and those components under their own names, as slices to zip. Tables come
/// in the World's field order, and which ones match is known at compile time.
pub fn query(world: anytype, comptime wanted: anytype) [tableCount(@TypeOf(world.*), wanted)]Zipped(@TypeOf(world.*), wanted) {
    const Tables = @TypeOf(world.*);
    var result: [tableCount(Tables, wanted)]Zipped(Tables, wanted) = undefined;
    var n: usize = 0;
    inline for (@typeInfo(Tables).@"struct".fields) |table| {
        if (comptime hasAll(table.type.Row, wanted)) {
            const t = &@field(world.*, table.name);
            result[n].ids = t.liveIds();
            inline for (wanted) |component| @field(result[n], @tagName(component)) = t.items(component);
            n += 1;
        }
    }
    return result;
}

fn hasAll(comptime Row: type, comptime wanted: anytype) bool {
    inline for (wanted) |component| if (!@hasField(Row, @tagName(component))) return false;
    return true;
}

fn tableCount(comptime Tables: type, comptime wanted: anytype) usize {
    var n: usize = 0;
    for (@typeInfo(Tables).@"struct".fields) |table| n += @intFromBool(hasAll(table.type.Row, wanted));
    return n;
}

/// What `query` gives for one table: `ids`, and one slice per component in
/// `wanted`. Every matching table must give a component the same type.
fn Zipped(comptime Tables: type, comptime wanted: anytype) type {
    const tables = @typeInfo(Tables).@"struct".fields;
    const Row = for (tables) |table| {
        if (hasAll(table.type.Row, wanted)) break table.type.Row;
    } else @compileError("no table has all of these components");
    for (tables) |table| {
        if (!hasAll(table.type.Row, wanted)) continue;
        for (wanted) |component| {
            if (@FieldType(table.type.Row, @tagName(component)) != @FieldType(Row, @tagName(component)))
                @compileError("tables disagree on the type of component \"" ++ @tagName(component) ++ "\"");
        }
    }

    var names: [wanted.len + 1][:0]const u8 = undefined;
    var types: [wanted.len + 1]type = undefined;
    names[0] = "ids";
    types[0] = []const Id;
    for (wanted, names[1..], types[1..]) |component, *name, *T| {
        name.* = @tagName(component);
        T.* = []@FieldType(Row, @tagName(component));
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

const testing = std.testing;

const Vec2 = struct { x: i32, y: i32 };

const TestWorld = struct {
    players: Table(2, struct { name: u8, position: Vec2 }),
    movers: Table(4, struct { position: Vec2, velocity: Vec2 }),
    sparks: Table(3, struct { velocity: Vec2, age: u8 }),

    const empty: TestWorld = .{ .players = .empty, .movers = .empty, .sparks = .empty };
};

fn olderThan(limit: u8, _: Id, row: anytype) bool {
    return row.age > limit;
}

fn isId(id: Id, row_id: Id, _: anytype) bool {
    return id == row_id;
}

test "a spawn takes effect at once" {
    var w: TestWorld = .empty;
    const id = w.movers.spawn(.{ .position = .{ .x = 1, .y = 2 }, .velocity = .{ .x = 3, .y = 4 } }).?;
    try testing.expectEqual(1, w.movers.len);
    try testing.expectEqual(3, w.movers.free());
    try testing.expectEqualSlices(Id, &.{id}, w.movers.liveIds());
    try testing.expectEqual(Vec2{ .x = 1, .y = 2 }, w.movers.items(.position)[0]);
}

test "a query zips the components of every table that has them" {
    var w: TestWorld = .empty;
    _ = w.players.spawn(.{ .name = 'a', .position = .{ .x = 0, .y = 0 } });
    _ = w.movers.spawn(.{ .position = .{ .x = 10, .y = 10 }, .velocity = .{ .x = 3, .y = -1 } });
    _ = w.movers.spawn(.{ .position = .{ .x = 20, .y = 20 }, .velocity = .{ .x = -2, .y = 5 } });
    _ = w.sparks.spawn(.{ .velocity = .{ .x = 1, .y = 1 }, .age = 0 });

    try testing.expectEqual(2, query(&w, .{.position}).len); // players and movers
    try testing.expectEqual(2, query(&w, .{.velocity}).len); // movers and sparks
    try testing.expectEqual(3, query(&w, .{}).len);

    const moving = query(&w, .{ .position, .velocity });
    try testing.expectEqual(1, moving.len);
    try testing.expectEqualSlices(Id, w.movers.liveIds(), moving[0].ids);
    for (moving) |rows| {
        for (rows.position, rows.velocity) |*position, velocity| {
            position.x += velocity.x;
            position.y += velocity.y;
        }
    }
    try testing.expectEqualSlices(Vec2, &.{ .{ .x = 13, .y = 9 }, .{ .x = 18, .y = 25 } }, w.movers.items(.position));
}

test "removeIf keeps the other rows in order and frees the removed ids" {
    var w: TestWorld = .empty;
    for (0..3) |age| _ = w.sparks.spawn(.{ .velocity = .{ .x = 0, .y = 0 }, .age = @intCast(age * 10) });
    try testing.expectEqualSlices(Id, &.{ 0, 1, 2 }, w.sparks.liveIds());

    w.sparks.removeIf(@as(u8, 5), olderThan);
    try testing.expectEqualSlices(Id, &.{0}, w.sparks.liveIds());
    try testing.expectEqualSlices(u8, &.{0}, w.sparks.items(.age));

    _ = w.movers.spawn(.{ .position = .{ .x = 1, .y = 1 }, .velocity = .{ .x = 0, .y = 0 } });
    _ = w.movers.spawn(.{ .position = .{ .x = 2, .y = 2 }, .velocity = .{ .x = 0, .y = 0 } });
    _ = w.movers.spawn(.{ .position = .{ .x = 3, .y = 3 }, .velocity = .{ .x = 0, .y = 0 } });
    w.movers.removeIf(@as(Id, 1), isId);
    try testing.expectEqualSlices(Id, &.{ 0, 2 }, w.movers.liveIds());
    try testing.expectEqualSlices(Vec2, &.{ .{ .x = 1, .y = 1 }, .{ .x = 3, .y = 3 } }, w.movers.items(.position));
    try testing.expect(!w.movers.in_use.isSet(1));
}

test "a full table refuses and counts" {
    var w: TestWorld = .empty;
    for (0..2) |name| _ = w.players.spawn(.{ .name = @intCast(name), .position = .{ .x = 0, .y = 0 } }).?;
    try testing.expectEqual(0, w.players.free());
    try testing.expectEqual(null, w.players.spawn(.{ .name = 2, .position = .{ .x = 0, .y = 0 } }));
    try testing.expectEqual(null, w.players.spawn(.{ .name = 3, .position = .{ .x = 0, .y = 0 } }));
    try testing.expectEqual(2, w.players.dropped);
    try testing.expectEqual(2, w.players.len);
}

test "an id comes back only after the counter wraps, and never while in use" {
    var t: Table(4, struct { age: u8 }) = .empty;
    const kept = t.spawn(.{ .age = 0 }).?;
    const first = t.spawn(.{ .age = 1 }).?;
    t.removeIf(first, isId);

    // 256 minus the capacity spawns, at least, before `first` returns.
    for (0..252) |_| {
        const id = t.spawn(.{ .age = 1 }).?;
        try testing.expect(id != first);
        try testing.expect(id != kept);
        t.removeIf(id, isId);
    }
    var seen: std.StaticBitSet(256) = .empty;
    for (0..3) |_| seen.set(t.spawn(.{ .age = 1 }).?);
    try testing.expect(!seen.isSet(kept));
    try testing.expectEqual(null, t.spawn(.{ .age = 1 }));
}

test "a spawn inside a loop over the same table is not visited" {
    var w: TestWorld = .empty;
    _ = w.movers.spawn(.{ .position = .{ .x = 0, .y = 0 }, .velocity = .{ .x = 1, .y = 0 } });
    _ = w.movers.spawn(.{ .position = .{ .x = 0, .y = 0 }, .velocity = .{ .x = 1, .y = 0 } });
    var visited: usize = 0;
    for (w.movers.items(.position)) |position| {
        _ = w.movers.spawn(.{ .position = position, .velocity = .{ .x = 0, .y = 0 } });
        visited += 1;
    }
    try testing.expectEqual(2, visited);
    try testing.expectEqual(4, w.movers.len);
}

test "a table of 256 rows uses every id" {
    const state = struct {
        var t: Table(256, struct { position: Vec2 }) = .empty;
    };
    for (0..256) |_| _ = state.t.spawn(.{ .position = .{ .x = 0, .y = 0 } }).?;
    try testing.expectEqual(null, state.t.spawn(.{ .position = .{ .x = 0, .y = 0 } }));
    try testing.expectEqual(256, state.t.in_use.count());
}
