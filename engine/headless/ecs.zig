//! A minimal entity-component-system (ADR 0003): a world of at most `capacity`
//! entities, one array and one bit set per component type, and queries that
//! combine bit sets. A world is one plain value: nothing is ever allocated.
//!
//! The Engine knows nothing about the components. Each program declares its
//! own as the fields of a struct, and `World` builds the storage from it:
//!
//!     const Components = struct { position: Vec2, velocity: Vec2, networked: void };
//!     var world: World(Components, 1024) = .{};
//!
//!     const ship = world.spawn() orelse return; // null: the world is full
//!     world.set(ship, .position, .{ .x = 64, .y = 90 });
//!     world.set(ship, .velocity, .{ .x = 6, .y = 0 });
//!
//!     var rows = world.query(&.{ .position, .velocity });
//!     while (rows.next()) |row| row.position.x += row.velocity.x;
//!
//!     world.destroy(ship);
//!     world.flush(); // once per Tick or Frame, after every system has run
//!
//! Spawns and destroys are deferred to `flush`, so the set of entities never
//! changes while the systems run: a spawned entity joins queries at the next
//! `flush`, and a destroyed one stays readable until then. Components, on the
//! other hand, are added and removed at once.
//!
//! Queries visit entities in ascending slot order, and `spawn` reuses the
//! lowest free slot, so the same calls always give the same world: a Match
//! with a seeded generator can be replayed in tests.

const std = @import("std");

/// A handle to an entity. Slots are reused once an entity is destroyed, and
/// `generation` tells the old occupant's handles from the new one's: a handle
/// whose generation is not the slot's current one is stale, and every method
/// treats it as an entity that no longer exists.
pub const Entity = packed struct(u32) {
    index: u16,
    generation: u16,
};

/// A world of at most `capacity` entities, whose component types are the
/// fields of `Components`. A field of type `void` is a tag: an entity has it
/// or not, and it holds no data.
pub fn World(comptime Components: type, comptime capacity: u16) type {
    const fields = @typeInfo(Components).@"struct".fields;
    if (capacity == 0) @compileError("a World needs room for at least one entity");
    if (@hasField(Components, "entity")) @compileError("\"entity\" is reserved for the handle in query rows");

    return struct {
        const Self = @This();

        /// One name per component type, the fields of `Components`.
        pub const Component = std.meta.FieldEnum(Components);
        /// One bit per slot.
        pub const Slots = std.StaticBitSet(capacity);

        /// The type a component holds.
        pub fn Type(comptime component: Component) type {
            return @FieldType(Components, @tagName(component));
        }

        /// One array per component type, indexed by slot. A value is only
        /// meaningful where the component's bit is set in `masks`.
        const Columns = columns: {
            var names: [fields.len][:0]const u8 = undefined;
            var types: [fields.len]type = undefined;
            for (fields, &names, &types) |field, *name, *T| {
                name.* = field.name;
                T.* = [capacity]field.type;
            }
            break :columns @Struct(.auto, null, &names, &types, &@splat(.{}));
        };

        columns: Columns = undefined,
        /// Which slots have each component.
        masks: std.EnumArray(Component, Slots) = .initFill(.initEmpty()),
        generations: [capacity]u16 = @splat(0),
        /// Slots held by an entity, from `spawn` until the `flush` after its
        /// `destroy`.
        claimed: Slots = .initEmpty(),
        /// Slots that queries visit: claimed, and flushed since `spawn`.
        active: Slots = .initEmpty(),
        /// Spawned since the last `flush`.
        spawning: Slots = .initEmpty(),
        /// Destroyed since the last `flush`.
        destroying: Slots = .initEmpty(),
        /// Spawns refused because every slot was claimed.
        dropped_spawns: u32 = 0,

        /// A new entity with no components, which joins queries at the next
        /// `flush`. Null, and counted in `dropped_spawns`, if the world is full.
        pub fn spawn(w: *Self) ?Entity {
            const index = w.claimed.complement().findFirstSet() orelse {
                w.dropped_spawns +|= 1;
                return null;
            };
            w.claimed.set(index);
            w.spawning.set(index);
            return w.handle(index);
        }

        /// Queues `entity` for removal at the next `flush`; until then, it
        /// stays in queries and its components stay readable. Does nothing if
        /// the handle is stale, or if the entity is already queued.
        pub fn destroy(w: *Self, entity: Entity) void {
            if (w.exists(entity)) w.destroying.set(entity.index);
        }

        /// Applies the spawns and destroys queued since the last call: spawned
        /// entities join queries, destroyed ones lose their components and
        /// their handles go stale. Call it once per Tick or Frame, after the
        /// systems.
        pub fn flush(w: *Self) void {
            w.active.setUnion(w.spawning);
            w.spawning = .initEmpty();

            const kept = w.destroying.complement();
            w.claimed.setIntersection(kept);
            w.active.setIntersection(kept);
            for (&w.masks.values) |*mask| mask.setIntersection(kept);
            var destroyed = w.destroying.iterator(.{});
            while (destroyed.next()) |index| w.generations[index] +%= 1;
            w.destroying = .initEmpty();
        }

        /// Whether `entity` still refers to the entity it was made for: true
        /// from its `spawn` until the `flush` after its `destroy`.
        pub fn exists(w: *const Self, entity: Entity) bool {
            return entity.index < capacity and
                w.claimed.isSet(entity.index) and
                w.generations[entity.index] == entity.generation;
        }

        /// Entities that queries visit.
        pub fn count(w: *const Self) usize {
            return w.active.count();
        }

        /// Gives `entity` the component, or replaces its value. Does nothing if
        /// the handle is stale.
        pub fn set(w: *Self, entity: Entity, comptime component: Component, value: Type(component)) void {
            if (!w.exists(entity)) return;
            @field(w.columns, @tagName(component))[entity.index] = value;
            w.masks.getPtr(component).set(entity.index);
        }

        /// Takes the component away from `entity`. Does nothing if the handle
        /// is stale or the entity lacks it.
        pub fn remove(w: *Self, entity: Entity, comptime component: Component) void {
            if (w.exists(entity)) w.masks.getPtr(component).unset(entity.index);
        }

        /// The component's value, or null if the handle is stale or the entity
        /// lacks it. The pointer stays valid until the component is removed or
        /// the entity is flushed away.
        pub fn get(w: *Self, entity: Entity, comptime component: Component) ?*Type(component) {
            if (!w.has(entity, component)) return null;
            return &@field(w.columns, @tagName(component))[entity.index];
        }

        pub fn has(w: *const Self, entity: Entity, comptime component: Component) bool {
            return w.exists(entity) and w.masks.getPtrConst(component).isSet(entity.index);
        }

        /// What a query yields for each entity: its handle as `entity`, and a
        /// pointer to each requested component, under the component's name.
        pub fn Row(comptime with: []const Component) type {
            var names: [with.len + 1][:0]const u8 = undefined;
            var types: [with.len + 1]type = undefined;
            names[0] = "entity";
            types[0] = Entity;
            for (with, names[1..], types[1..]) |component, *name, *T| {
                name.* = @tagName(component);
                T.* = *Type(component);
            }
            return @Struct(.auto, null, &names, &types, &@splat(.{}));
        }

        pub fn Query(comptime with: []const Component) type {
            return struct {
                world: *Self,
                /// Matching slots not visited yet.
                remaining: Slots,

                pub fn next(q: *@This()) ?Row(with) {
                    const index = q.remaining.findFirstSet() orelse return null;
                    q.remaining.unset(index);
                    var row: Row(with) = undefined;
                    row.entity = q.world.handle(index);
                    inline for (with) |component| {
                        @field(row, @tagName(component)) = &@field(q.world.columns, @tagName(component))[index];
                    }
                    return row;
                }
            };
        }

        /// The active entities that have every component in `with`, in
        /// ascending slot order. Which entities match is decided here, once:
        /// components added or removed during the walk do not change it.
        pub fn query(w: *Self, comptime with: []const Component) Query(with) {
            var matching = w.active;
            inline for (with) |component| matching.setIntersection(w.masks.get(component));
            return .{ .world = w, .remaining = matching };
        }

        fn handle(w: *const Self, index: usize) Entity {
            return .{ .index = @intCast(index), .generation = w.generations[index] };
        }
    };
}

const testing = std.testing;

const Vec2 = struct { x: i32, y: i32 };
const TestWorld = World(struct { position: Vec2, velocity: Vec2, networked: void }, 4);

test "a spawned entity joins queries at the next flush" {
    var w: TestWorld = .{};
    const e = w.spawn().?;
    w.set(e, .position, .{ .x = 1, .y = 2 });
    try testing.expect(w.exists(e));
    try testing.expectEqual(0, w.count());

    var before = w.query(&.{.position});
    try testing.expectEqual(null, before.next());

    w.flush();
    var after = w.query(&.{.position});
    const row = after.next().?;
    try testing.expectEqual(e, row.entity);
    try testing.expectEqual(Vec2{ .x = 1, .y = 2 }, row.position.*);
    try testing.expectEqual(null, after.next());
}

test "a query yields exactly the entities that have every requested component" {
    var w: TestWorld = .{};
    const moving = w.spawn().?;
    const still = w.spawn().?;
    const tagged = w.spawn().?;
    w.set(moving, .position, .{ .x = 0, .y = 0 });
    w.set(moving, .velocity, .{ .x = 3, .y = -1 });
    w.set(still, .position, .{ .x = 5, .y = 5 });
    w.set(tagged, .networked, {});
    w.flush();

    var rows = w.query(&.{ .position, .velocity });
    while (rows.next()) |row| {
        row.position.x += row.velocity.x;
        row.position.y += row.velocity.y;
    }
    try testing.expectEqual(Vec2{ .x = 3, .y = -1 }, w.get(moving, .position).?.*);
    try testing.expectEqual(Vec2{ .x = 5, .y = 5 }, w.get(still, .position).?.*);

    var networked = w.query(&.{.networked});
    try testing.expectEqual(tagged, networked.next().?.entity);
    try testing.expectEqual(null, networked.next());

    var all = w.query(&.{});
    var seen: usize = 0;
    while (all.next()) |_| seen += 1;
    try testing.expectEqual(3, seen);
}

test "removing a component takes the entity out of matching queries" {
    var w: TestWorld = .{};
    const e = w.spawn().?;
    w.set(e, .velocity, .{ .x = 1, .y = 1 });
    w.flush();
    w.remove(e, .velocity);
    try testing.expect(!w.has(e, .velocity));
    var rows = w.query(&.{.velocity});
    try testing.expectEqual(null, rows.next());
}

test "a destroy during a query takes effect at the next flush" {
    var w: TestWorld = .{};
    for (0..3) |_| w.set(w.spawn().?, .position, .{ .x = 0, .y = 0 });
    w.flush();

    var rows = w.query(&.{.position});
    var visited: usize = 0;
    while (rows.next()) |row| {
        w.destroy(row.entity);
        try testing.expect(w.exists(row.entity));
        visited += 1;
    }
    try testing.expectEqual(3, visited);
    try testing.expectEqual(3, w.count());

    w.flush();
    try testing.expectEqual(0, w.count());
}

test "a reused slot makes the old handle stale" {
    var w: TestWorld = .{};
    const old = w.spawn().?;
    w.set(old, .position, .{ .x = 1, .y = 1 });
    w.flush();
    w.destroy(old);
    w.flush();

    const new = w.spawn().?;
    try testing.expectEqual(old.index, new.index);
    try testing.expect(old.generation != new.generation);
    try testing.expect(!w.exists(old));
    try testing.expect(w.exists(new));

    // The new occupant starts with no components, and the old handle reaches nothing.
    try testing.expect(!w.has(new, .position));
    w.set(old, .position, .{ .x = 9, .y = 9 });
    try testing.expect(!w.has(new, .position));
    w.set(new, .position, .{ .x = 2, .y = 2 });
    try testing.expectEqual(null, w.get(old, .position));
    w.destroy(old);
    w.flush();
    try testing.expect(w.exists(new));
}

test "a spawn into a full world is dropped and counted" {
    var w: TestWorld = .{};
    for (0..4) |_| _ = w.spawn().?;
    try testing.expectEqual(null, w.spawn());
    try testing.expectEqual(null, w.spawn());
    try testing.expectEqual(2, w.dropped_spawns);

    // A destroyed slot is only free again after the flush.
    w.destroy(.{ .index = 0, .generation = 0 });
    try testing.expectEqual(null, w.spawn());
    w.flush();
    try testing.expect(w.spawn() != null);
}

test "an entity spawned and destroyed before a flush never joins queries" {
    var w: TestWorld = .{};
    const e = w.spawn().?;
    w.destroy(e);
    w.flush();
    try testing.expect(!w.exists(e));
    try testing.expectEqual(0, w.count());
}

test "a handle outside the world is stale" {
    var w: TestWorld = .{};
    try testing.expect(!w.exists(.{ .index = 4, .generation = 0 }));
    try testing.expect(!w.exists(.{ .index = std.math.maxInt(u16), .generation = 0 }));
    w.destroy(.{ .index = 4, .generation = 0 });
    try testing.expectEqual(null, w.get(.{ .index = 4, .generation = 0 }, .position));
}

test "a full-size world is one plain value" {
    const Big = World(struct { position: Vec2, velocity: Vec2, networked: void }, 1024);
    const state = struct {
        var w: Big = .{};
    };
    const e = state.w.spawn().?;
    state.w.set(e, .position, .{ .x = 0, .y = 0 });
    state.w.flush();
    try testing.expectEqual(1, state.w.count());
}
