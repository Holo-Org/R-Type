# R-Type

A networked horizontal shoot'em up for up to four players, built on a home-made, game-agnostic engine: a Server runs each Match and has the final say, and each Player sees and plays it through a Client.

## Language

### Codebase

**Engine**:
The game-agnostic part of the codebase: everything that remains once R-Type's rules, world and assets are taken out.
_Avoid_: framework, core

**Game**:
R-Type's rules, world and assets, built on top of the Engine.
_Avoid_: game (for a single play-through, use Match)

**World**:
Where a program keeps the things it moves and draws: on the Server, the Match's entities; on each Client, what only that Client draws, such as explosions.
_Avoid_: registry, scene, level, world (for the play area, which is the screen)

### Programs and people

**Server**:
The program that runs Matches and has final authority over everything that happens in them.
_Avoid_: host

**Client**:
The program through which a Player joins a Match, sees it and controls a Ship.

**Player**:
A person taking part in a Match through a Client.
_Avoid_: user, client (for the person)

### Play

**Match**:
One play-through shared by up to four Players, from the first Player joining to game over.
_Avoid_: game, session, instance, room

**Join window**:
The first part of a Match, before any Enemy appears, and the only time a Client can join it.
_Avoid_: grace period, lobby, countdown

**Game over**:
The end of a Match, once no Ship is left.

**Entity**:
A Ship, an Enemy or a Projectile: anything in a Match whose position a Snapshot carries.
_Avoid_: object, actor, unit

**Ship**:
The entity a Player controls during a Match.
_Avoid_: spaceship, player (for the entity)

**Hit points**:
How many more hits a Ship or an Enemy can take; at zero, it is destroyed.
_Avoid_: life, lives, health

**Invulnerability**:
The period after a hit during which a Ship can neither be hurt nor fire.
_Avoid_: immunity, invincibility, grace period

**Enemy**:
A hostile entity controlled by the Server.
_Avoid_: monster, mob, Bydo (the in-story name of the enemy faction)

**Dart**:
A fast Enemy that weaves in a line with the rest of its Wave and never fires.
_Avoid_: fighter

**Pod**:
A slow Enemy that takes several hits and fires at the nearest Ship.
_Avoid_: turret, dome

**Projectile**:
Anything fired that harms on contact; it always has an owner, either a Ship or an Enemy.
_Avoid_: missile, bullet, shot

**Wave**:
A group of Enemies spawned together.
_Avoid_: spawn group

**Star-field**:
The scrolling space background of a Match.
_Avoid_: background, parallax

**Action**:
Something a Player can ask their Ship to do (move up, down, left or right, or fire), whichever key or button they bound to it.
_Avoid_: command, key, button

### Between Client and Server

**Input**:
The Actions a Player holds during one Tick, as their Client sends them to the Server.
_Avoid_: keys, buttons, command

**Snapshot**:
Where every entity of a Match stands at one Tick, as the Server sends it to a Client; each Snapshot replaces the one before.
_Avoid_: state update, world update, sync

**Announcement**:
Something that happened in a Match that every Player must learn of, such as a Player joining, leaving or timing out, an explosion, a Ship destroyed, or game over; unlike a Snapshot, it is delivered for certain.
_Avoid_: event (kept for the Engine's internal messages), notification

**Connection**:
The link between one Client and the Server, from the moment the Server accepts the Client until the Client disconnects, or either side stops hearing from the other.
_Avoid_: session

**Refusal**:
The Server's answer to a connect it cannot take, giving the reason: the Match is full, or it has already started.
_Avoid_: reject, rejection

### Time

**Tick**:
One fixed step of the Server's simulation of a Match.
_Avoid_: frame, update, turn

**Frame**:
One image rendered by a Client.
_Avoid_: tick
