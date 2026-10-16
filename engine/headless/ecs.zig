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
            _ = w;
            @panic("not implemented yet: #22");
        }

        /// Queues `entity` for removal at the next `flush`; until then, it
        /// stays in queries and its components stay readable. Does nothing if
        /// the handle is stale, or if the entity is already queued.
        pub fn destroy(w: *Self, entity: Entity) void {
            _ = .{ w, entity };
            @panic("not implemented yet: #22");
        }

        /// Applies the spawns and destroys queued since the last call: spawned
        /// entities join queries, destroyed ones lose their components and
        /// their handles go stale. Call it once per Tick or Frame, after the
        /// systems.
        pub fn flush(w: *Self) void {
            _ = w;
            @panic("not implemented yet: #22");
        }

        /// Whether `entity` still refers to the entity it was made for: true
        /// from its `spawn` until the `flush` after its `destroy`.
        pub fn exists(w: *const Self, entity: Entity) bool {
            _ = .{ w, entity };
            @panic("not implemented yet: #22");
        }

        /// Entities that queries visit.
        pub fn count(w: *const Self) usize {
            _ = w;
            @panic("not implemented yet: #22");
        }

        /// Gives `entity` the component, or replaces its value. Does nothing if
        /// the handle is stale.
        pub fn set(w: *Self, entity: Entity, comptime component: Component, value: Type(component)) void {
            _ = .{ w, entity, component, value };
            @panic("not implemented yet: #22");
        }

        /// Takes the component away from `entity`. Does nothing if the handle
        /// is stale or the entity lacks it.
        pub fn remove(w: *Self, entity: Entity, comptime component: Component) void {
            _ = .{ w, entity, component };
            @panic("not implemented yet: #22");
        }

        /// The component's value, or null if the handle is stale or the entity
        /// lacks it. The pointer stays valid until the component is removed or
        /// the entity is flushed away.
        pub fn get(w: *Self, entity: Entity, comptime component: Component) ?*Type(component) {
            _ = .{ w, entity, component };
            @panic("not implemented yet: #22");
        }

        pub fn has(w: *const Self, entity: Entity, comptime component: Component) bool {
            _ = .{ w, entity, component };
            @panic("not implemented yet: #22");
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
                    _ = q;
                    @panic("not implemented yet: #22");
                }
            };
        }

        /// The active entities that have every component in `with`, in
        /// ascending slot order. Which entities match is decided here, once:
        /// components added or removed during the walk do not change it.
        pub fn query(w: *Self, comptime with: []const Component) Query(with) {
            _ = .{ w, with };
            @panic("not implemented yet: #22");
        }
    };
}

const testing = std.testing;

const Vec2 = struct { x: i32, y: i32 };
const TestWorld = World(struct { position: Vec2, velocity: Vec2, networked: void }, 4);

/// Every call the Game and both programs will make, so that the compiler
/// checks the whole interface. Never run: the bodies come with #22.
fn usage(w: *TestWorld) void {
    const e = w.spawn() orelse return;
    w.set(e, .position, .{ .x = 64, .y = 90 });
    w.set(e, .networked, {});
    if (w.get(e, .position)) |position| position.x += 1;
    if (w.has(e, .velocity)) w.remove(e, .velocity);
    var rows = w.query(&.{ .position, .velocity });
    while (rows.next()) |row| {
        row.position.x += row.velocity.x;
        if (!w.exists(row.entity)) unreachable;
    }
    _ = w.count();
    w.destroy(e);
    w.flush();
}

test "the interface compiles" {
    _ = &usage;
    try testing.expectEqual(@sizeOf(u32), @sizeOf(Entity));
}
