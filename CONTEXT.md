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
One play-through shared by up to four Players, from its start to game over.
_Avoid_: game, session, instance, room

**Ship**:
The entity a Player controls during a Match.
_Avoid_: spaceship, player (for the entity)

**Enemy**:
A hostile entity controlled by the Server.
_Avoid_: monster, mob, Bydo (the in-story name of the enemy faction)

**Projectile**:
Anything fired that harms on contact; it always has an owner, either a Ship or an Enemy.
_Avoid_: missile, bullet, shot

**Wave**:
A group of Enemies spawned together.
_Avoid_: spawn group

**Star-field**:
The scrolling space background of a Match.
_Avoid_: background, parallax

### Time

**Tick**:
One fixed step of the Server's simulation of a Match.
_Avoid_: frame, update, turn

**Frame**:
One image rendered by a Client.
_Avoid_: tick
