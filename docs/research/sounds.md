# Sounds for Part 1

Last verified: 2026-10-16.

This note answers the decision-map ticket [Where do the sounds come from? (#6)](https://github.com/Holo-Org/R-Type/issues/6). The provided assets hold sprites only. The subject asks only that we "think about basic sound design" in Part 1 (Gameplay section of the subject, `docs/subject/B-CPP-500_rtype.pdf`). It lists "music (or even better, procedural music)" among the ideas for Part 2, not Part 1.

This is input for a team decision, so it sets out options with their trade-offs. Every fact links to its source. Lines marked **Assessment** or **Inference** are judgement, not fact. Nobody on the team, and not the author of this note, has listened to any sound named here: the quality of every generated or downloaded sound is **not verified**.

## Versions and sources checked

| Item | Version | Source |
| --- | --- | --- |
| raylib | 6.0, tag `6.0` = commit `dbc56a87da87d973a9c5baa4e7438a9d20121d28` | [GitHub ref API](https://api.github.com/repos/raysan5/raylib/git/ref/tags/6.0) |
| raylib-zig | commit `8758f4cd3a5ae0df6941c4715257223d34c5ad3e` (the one pinned in the Zig POC) | [build.zig.zon](https://github.com/raylib-zig/raylib-zig/blob/8758f4cd3a5ae0df6941c4715257223d34c5ad3e/build.zig.zon) |
| Zig | 0.16.0 | [language reference](https://ziglang.org/documentation/0.16.0/) |

The raylib-zig commit depends on raylib at `git+https://github.com/raysan5/raylib#6.0`, so the raylib source read below is the one the Zig POC builds ([build.zig.zon, `.raylib`](https://github.com/raylib-zig/raylib-zig/blob/8758f4cd3a5ae0df6941c4715257223d34c5ad3e/build.zig.zon)).

## 1. Which sounds Part 1 needs

The moments come from the rules decided so far and from [ADR 0002](../adr/0002-snapshots-and-a-reliable-channel.md): an explosion, a Ship destroyed and game over reach a Client as Announcements (delivered for certain); a Projectile appearing or a Ship's hit points dropping are noticed by comparing Snapshots. The accessibility commitments say every important sound has a visual cue, so the third column states the cue each sound needs; the cues are not part of this ticket.

| # | Moment | How the Client learns of it | Visual cue it needs | Priority |
| --- | --- | --- | --- | --- |
| 1 | A Ship fires a Projectile | a new Projectile in a Snapshot | the Projectile itself, plus a muzzle flash if wanted | needed |
| 2 | An Enemy fires a Projectile | a new Projectile in a Snapshot | the Projectile itself | optional |
| 3 | An Enemy is destroyed | an explosion Announcement | the explosion drawing | needed |
| 4 | A Ship is hit (hit points drop, 4 s of invulnerability starts) | hit points drop between two Snapshots | the Ship drawn steadily see-through while invulnerable (never blinking: no flicker is an accessibility commitment) | needed |
| 5 | A Ship is destroyed | a Ship destroyed Announcement | a larger explosion drawing | needed |
| 6 | Join window countdown (a tick per second, then a start cue) | the Match's countdown state | the number on screen | optional |
| 7 | A Player joins or leaves | an Announcement | a line of text | optional |
| 8 | Game over | an Announcement | a message on screen | optional |
| 9 | Music during the Match | none (local to the Client) | none needed, but a volume setting | needed if the "separate volumes" commitment is to mean anything |

A Ship is invulnerable and cannot fire for 4 s after a hit; a sound for "you can fire again" is possible, but I would not count it as needed (**Assessment**).

Two implementation facts from the raylib source bear on rows 1 and 3:

- `PlaySound` restarts the sound's buffer from the beginning ([`PlayAudioBuffer`, raudio.c:662](https://github.com/raysan5/raylib/blob/6.0/src/raudio.c#L662): "Buffer is restarted to the start"). A fast stream of firing sounds from four Ships on one `Sound` would therefore cut itself off. `LoadSoundAlias` creates a second `Sound` that shares the first one's sample data ([raudio.c:985](https://github.com/raysan5/raylib/blob/6.0/src/raudio.c#L985)), and raylib-zig exposes it ([`loadSoundAlias`](https://github.com/raylib-zig/raylib-zig/blob/8758f4cd3a5ae0df6941c4715257223d34c5ad3e/lib/raylib.zig#L5154)). **Inference**: a small pool of aliases per effect would let sounds overlap. The Zig POC's `Sound` plays a single buffer, so this is new Engine work either way.
- `SetMasterVolume` scales the whole output ([raudio.c:556](https://github.com/raysan5/raylib/blob/6.0/src/raudio.c#L556)); `SetSoundVolume` and `SetMusicVolume` scale one `Sound` or `Music` ([header](https://github.com/raysan5/raylib/blob/6.0/src/raylib.h#L1689)). **Inference**: separate music and effects volumes mean applying the effects volume to every `Sound` and alias, and the music volume to the `Music`, not using the master volume.

## 2. Generated in code or licensed asset

What the Zig POC does today: `client/sound.zig` fills an array of 7,938 16-bit mono samples (a square wave sweeping from 1400 Hz to 300 Hz in 0.18 s, with a fading envelope), and `AudioDevice.loadSound` wraps them in a `Wave` and calls `LoadSoundFromWave`, which copies them into raylib's own buffer ([sound.zig](https://github.com/Holo-Org/R-Type/blob/ca23b7b2b771e0f0340f7d3206aebdbf843fa317/prototypes/lang-zig/client/sound.zig), [engine/client/root.zig, `loadSound`](https://github.com/Holo-Org/R-Type/blob/ca23b7b2b771e0f0340f7d3206aebdbf843fa317/prototypes/lang-zig/engine/client/root.zig#L189)). The POC report says the sound was played without error but nobody listened to it ([REPORT.md, "As in the other POCs…"](https://github.com/Holo-Org/R-Type/blob/ca23b7b2b771e0f0340f7d3206aebdbf843fa317/prototypes/lang-zig/REPORT.md)).

### Generated in code

- **For**: no licence, no attribution and no provenance to document; nothing is added to the repository's history except code; adds no bytes to the binary beyond the code; fully reproducible; one consistent retro character; the existing `loadSound` already takes the samples.
- **Against**: tuning by ear costs time, and a team that has not yet listened to its first sound has no evidence it can get a satisfying explosion this way; noise-based sounds (explosions, impacts) are harder to make convincing than tonal blips (**Assessment**); music is a separate, much larger design task.
- **Fits best**: rows 1, 2, 4, 6, 7, 8 (short, tonal or simple-envelope sounds).

### Licensed asset

- **For**: less tuning time, richer sounds, especially explosions; usually a few dozen KB per effect (see the Kenney file sizes below).
- **Against**: a provenance duty (a credits file naming source, author and licence); a wrong or later-changed licence cannot be taken back out of a public repository's history; every file adds to the binary if embedded; the Engine needs a "load a sound from encoded bytes" function (section 4); effects must be mixed to a consistent loudness (**Inference**: files from different packs will differ).
- **Fits best**: rows 3 and 5 (explosions) and row 9 (music).

### Options for music

| Option | Cost | Note |
| --- | --- | --- |
| None in Part 1 | none | leaves the music volume with nothing to control |
| A CC0 loop from OpenGameArt | licence check, 2 to 4 MB | candidates in section 3 |
| A tracker module (`.xm` or `.mod`) | tiny files | raylib loads both by default (section 4); I did not look for a licensed module |
| Generated in code | a day or more of design, **Assessment** | the subject names procedural music as a Part 2 idea |

### Recommendation (for the team to decide)

1. Generate rows 1, 2, 4, 6, 7 and 8 in code, extending `sound.zig`.
2. For rows 3 and 5, try a generated noise burst first; if it fails a listening test, use one or two CC0 files from Kenney's Sci-fi Sounds (`explosionCrunch_*`, `lowFrequency_explosion_*`).
3. For music, one CC0 OGG loop from OpenGameArt, or none in Part 1.
4. A house rule that keeps the licence question trivial: **only CC0 files, or files we generated, enter the repository**, with a credits file listing each source anyway.

The deadline is Sunday 18 October 2026, 23:42, so the first listening test should happen before anything else is built (**Assessment**).

## 3. Sources of freely licensed sounds

"Compatible with a public repository" is read here as: the licence lets us put the unmodified file in a public repository, which is redistribution, and lets people clone and build from it. I am not a lawyer, and this is not legal advice. The repository had no `LICENSE` file at its root on `main` (commit `c843b304`) when I checked, so which licence the project itself will carry is **unknown**, and it decides whether CC BY-SA or GPL assets would be a problem.

### Summary

| Source | Licence | Attribution | Files in a public repository | Verdict |
| --- | --- | --- | --- | --- |
| [Kenney](https://kenney.nl/support) | CC0 1.0 | not required | yes (CC0) | usable |
| [OpenGameArt](https://opengameart.org/content/faq), CC0 items only | CC0 1.0 | not required | yes (CC0) | usable, check each page |
| [Freesound](https://freesound.org/help/faq/), CC0 sounds only | CC0 1.0 | not required | yes (CC0) | usable, needs an account |
| Freesound or OpenGameArt, CC BY | CC BY 3.0 or 4.0 | required | yes, with the notices | possible, avoid for time reasons |
| CC BY-SA, GPL | share-alike | required | yes, but the licence of the combined work is in question | avoid |
| CC BY-NC (Freesound) | non-commercial | required | not suited to a project that may be reused | avoid |
| [incompetech](https://incompetech.com/music/royalty-free/faq.html) (Kevin MacLeod) | CC BY 4.0 | required, visible | the page is silent on repositories | possible for music, with credit |
| [Pixabay](https://pixabay.com/service/terms/) | Pixabay Content Licence | not required | no for unmodified files ("Standalone") | avoid |
| [Sonniss GDC bundles](https://sonniss.com/gdc-bundle-license/) | Sonniss licence | not required | no | avoid |
| [FreePD](https://freepd.com/) | "Public Domain" | n/a | n/a | site closed |
| jsfxr, sfxr | tool under Unlicense and MIT | n/a | sounds you generate are your own (**Inference**) | usable as a design aid |

### Kenney

- **Licence**: "public domain licensed (CC0)" for all game assets on its asset pages; credit is optional; the logo is reserved ([Kenney support page](https://kenney.nl/support)). The support page does not mention redistribution or repositories.
- **Pack check**: I downloaded `kenney_sci-fi-sounds.zip` (5.9 MB, [pack page](https://kenney.nl/assets/sci-fi-sounds), listing it as CC0, 70 files, version 1.0, 2020) into a scratch directory and read its contents without running anything. Its `License.txt` says: CC0 at `creativecommons.org/publicdomain/zero/1.0/`, "free to use in personal, educational and commercial projects", crediting Kenney "is not mandatory".
- **Redistribution**: the CC0 legal code waives all copyright "for any purpose whatsoever, including without limitation commercial, advertising or promotional purposes", "in any current or future medium and for any number of copies" ([CC0 1.0 legal code, section 2](https://creativecommons.org/publicdomain/zero/1.0/legalcode)). It does not waive trademark or patent rights (section 4). **Inference**: committing the files unmodified to a public repository is allowed.
- **Formats and content**: every audio file in this pack is `.ogg`. Relevant files and sizes: `laserSmall_000..004.ogg` (about 7 to 9 KB each), `laserRetro_000..004.ogg` (about 13 KB), `laserLarge_*` (about 26 KB), `explosionCrunch_000..004.ogg` (28 to 79 KB), `lowFrequency_explosion_000..001.ogg` (9 to 14 KB), `impactMetal_000..004.ogg` (11 to 17 KB), `forceField_*` (24 to 29 KB), plus engine and thruster loops.
- **Other audio packs**: [Digital Audio](https://kenney.nl/assets/digital-audio) (60 files, CC0, tagged "space" and "laser"), [Music Jingles](https://kenney.nl/assets/music-jingles) (85 files, CC0), [Impact Sounds](https://kenney.nl/assets/impact-sounds), [Interface Sounds](https://kenney.nl/assets/interface-sounds) and [UI Audio](https://kenney.nl/assets/ui-audio). I did not open these, so their file formats and exact contents are **not verified**. I found no Kenney pack of long looping music; Music Jingles are short pieces.

### OpenGameArt

- **Licences accepted**: CC0, CC-BY 3.0 and 4.0, CC-BY-SA 3.0 and 4.0, OGA-BY 3.0 and 4.0, GPL 2.0 and 3.0, chosen **per submission** by the artist, who may offer several ([FAQ](https://opengameart.org/content/faq)).
- **Attribution**: not needed for CC0; for the others, credit the creator, name the work and link to it; the FAQ suggests a credits file naming asset, author, licence and URL. The "Copyright/Attribution Notice" on each page is where the artist states how.
- **Previews**: "Unless otherwise noted, assume the previews are 'All rights reserved'". Download the file, not the preview.
- **Verification**: the FAQ says the site makes an effort to verify public-domain claims and tells uploaders of others' work to be certain of the licence. It does not say it verifies that submitters own their work. **Assessment**: licence metadata on OpenGameArt is only as reliable as the uploader, so a CC0 file there is a weaker guarantee than one from a named publisher such as Kenney.
- **Candidates read on 2026-10-16** (page licence field and file list only; none listened to):

  | Item | Licence | File |
  | --- | --- | --- |
  | [8-bit Epic Space Shooter Music](https://opengameart.org/content/8-bit-epic-space-shooter-music), HydroGene | CC0; credit "NOT mandatory"; author says it "loops seamlessly" | `8bit-spaceshooter.mp3`, 2 MB |
  | [Space Music: Out There](https://opengameart.org/content/space-music-out-there), yd | CC0 | `OutThere.ogg`, 3.9 MB, about 4 minutes, tagged "loop" |
  | [Simple BGM Loop](https://opengameart.org/content/simple-bgm-loop), Theforeshadower | CC0; "just don't claim you made it" | `LoopWIP1.ogg`, 1.1 MB |
  | [8-Bit Sound Effect Pack (Vol. 001)](https://opengameart.org/content/8-bit-sound-effect-pack-vol-001), Deva | CC0; asks to be credited as @Shades | 46 `.wav` files, including 5 explosions |

### Freesound

- **Licences**: one of three per sound, CC0, CC BY and CC BY-NC (a fourth, Sampling+, is being retired) ([FAQ, "What do I need to do to legally use the files"](https://freesound.org/help/faq/)). The uploader chooses ([terms](https://freesound.org/help/tos_web/): "You select the CC license for your sound").
- **Attribution**: not for CC0 ("you can do pretty much what you want with the sound", though not claim to be its author); required for CC BY; BY-NC forbids earning money from the work.
- **Account**: downloading requires being logged into a registered account.
- **Filter**: the search page has a licence filter. The FAQ describes its "Free Cultural Works" option as CC BY or CC0; whether it has a CC0-only option is **not verified**, so check the licence on each sound's page.
- **Reliability**: uploaders promise they may post the sound ([terms](https://freesound.org/help/tos_web/)); as with OpenGameArt, the guarantee is the uploader's.
- **Formats**: not verified. Original uploads may be in formats raylib does not load by default (FLAC is off, see section 4).

### Attribution when a licence needs it

CC BY 4.0, section 3(a): when sharing the material you must keep the creator's name, a copyright notice if supplied, a notice or link to the licence, an indication of modifications, and a link to the material "to the extent reasonably practicable"; it may be satisfied "in any reasonable manner" such as a link to a page with the information ([CC BY 4.0 legal code](https://creativecommons.org/licenses/by/4.0/legalcode)). incompetech asks for this wording, visible to the audience: `Title Kevin MacLeod (incompetech.com)` / `Licensed under Creative Commons: By Attribution 4.0` / the licence URL ([incompetech FAQ](https://incompetech.com/music/royalty-free/faq.html)). CC BY-SA 4.0 adds that adapted material must carry the same or a compatible licence (section 3(b), [legal code](https://creativecommons.org/licenses/by-sa/4.0/legalcode)).

### Sources ruled out, and why

- **Pixabay**: its terms bar selling or distributing content "on a Standalone basis", defined as "no creative effort has been applied" and "substantially the same form". Committing an unmodified file alone to a repository falls under that reading ([terms](https://pixabay.com/service/terms/)). The terms do not mention open-source projects, so this is an inference.
- **Sonniss GDC bundles**: "Licensee may not distribute, publish, sub-license or otherwise supply the sound effects as sound effects to any other person". Finished projects may be shared, but the raw files in a repository are the sound effects themselves ([licence](https://sonniss.com/gdc-bundle-license/)). The licence also does not mention public repositories, so this too is an inference.
- **FreePD**: the page now says the site is "permanently closed" ([freepd.com](https://freepd.com/)).
- **Not checked**: itch.io (licences per asset), Wikimedia Commons, ccMixter, Free Music Archive, The Mod Archive, Zapsplat and others.

### Generation tools

- [jsfxr](https://github.com/grumdrig/jsfxr) (a port of sfxr to HTML5) is under the Unlicense; [sfxr](https://www.drpetter.se/project_sfxr.html) is under the MIT licence. Neither page says anything about the licence of the sounds they produce. **Inference**: a sound you generate from your own parameters is your work, but I did not find a statement that settles it. Using them to design a sound, then reproducing it in Zig, avoids shipping the output at all.

## 4. What raylib 6.0 can load from memory

### The functions

- `LoadWaveFromMemory(fileType, fileData, dataSize)` decodes a whole file into a `Wave` in memory. `fileType` is the extension with its dot, "in lower-case" ([raudio.c:807](https://github.com/raysan5/raylib/blob/6.0/src/raudio.c#L807); the code compares against `.wav` and `.WAV`, so a mixed-case string fails).
- `LoadSoundFromWave(wave)` copies and converts the samples to the device format (32-bit float, stereo, the device's sample rate) into its own buffer, so the `Wave` can be unloaded straight after ([raudio.c:944](https://github.com/raysan5/raylib/blob/6.0/src/raudio.c#L944)). The POC already uses this call.
- `LoadMusicStreamFromMemory(fileType, data, dataSize)` opens a decoder on the buffer and streams from it as `UpdateMusicStream` is called ([raudio.c:1540](https://github.com/raysan5/raylib/blob/6.0/src/raudio.c#L1540)). For WAV, OGG, MP3, QOA and FLAC the decoder is opened directly on `data`; the MOD branch copies the buffer, and I did not check XM. **Inference**: the buffer must stay valid for as long as the `Music` lives, which an `@embedFile` array does (it is static). Looping is on by default (`music.looping = true`).
- raylib-zig wraps all three: `loadWaveFromMemory` and `loadMusicStreamFromMemory` take a `[:0]const u8` extension and a `[]const u8`, and return an error when the result is invalid ([raylib.zig:2531, 2553](https://github.com/raylib-zig/raylib-zig/blob/8758f4cd3a5ae0df6941c4715257223d34c5ad3e/lib/raylib.zig#L2531)).

### Formats

| Format | `LoadWaveFromMemory` | `LoadMusicStreamFromMemory` | On by default in `config.h` |
| --- | --- | --- | --- |
| WAV | yes, forced to 16-bit | yes | yes |
| OGG (Vorbis) | yes | yes | yes |
| MP3 | yes, as 32-bit float | yes | yes |
| QOA | yes | yes | yes |
| FLAC | yes | yes | **no** (`0`, "Disabled by default") |
| XM | no | yes | yes |
| MOD | no | yes | yes |

Sources: the two functions above, and [config.h lines 332 to 352](https://github.com/raysan5/raylib/blob/6.0/src/config.h#L332-L352), each flag guarded by `#ifndef`, so a compiler flag can override it. XM and MOD are tracker formats for music only; they cannot be loaded as a `Wave` or `Sound`.

### What raylib's own build does

- raylib's `build.zig` has an option `raudio` (default `true`) and an option `config`, "a list of space-separated cflags", passed to the C compiler for every source file ([build.zig:509 to 538](https://github.com/raysan5/raylib/blob/6.0/build.zig#L509-L538), flags added at [lines 179 to 190](https://github.com/raysan5/raylib/blob/6.0/build.zig#L179-L190)). It has no separate switch per audio format.
- raylib-zig at the pinned commit forwards `raudio` and `config` unchanged to raylib's build ([build.zig:49 to 65](https://github.com/raylib-zig/raylib-zig/blob/8758f4cd3a5ae0df6941c4715257223d34c5ad3e/build.zig#L49-L65)), and re-exports raylib's `Options`. It sets no format flag of its own. So at the pinned commit, **the defaults of raylib 6.0's `config.h` apply: WAV, OGG, MP3, QOA, XM and MOD, not FLAC.**
- **Inference**, not tested: passing `.config = "-DSUPPORT_FILEFORMAT_FLAC=1"` as an option to the `raylib_zig` dependency in `build.zig` would turn FLAC on. Nothing in this project needs it.
- The audio backend is miniaudio, with its own WAV, FLAC and MP3 decoders disabled (`MA_NO_WAV`, `MA_NO_FLAC`, `MA_NO_MP3`); raylib decodes with dr_wav, dr_mp3, stb_vorbis and others instead ([raudio.c:162 to 169](https://github.com/raysan5/raylib/blob/6.0/src/raudio.c#L162-L169)). No extra audio library is needed to link.

**Assessment**: OGG for effects and music, plus WAV, covers everything in section 3 with no build change. Kenney's pack is entirely OGG, and OpenGameArt offers OGG, MP3 and WAV. I would avoid MP3 for a loop: MP3 files often carry encoder padding that can leave a gap at the loop point. I have not verified that for raylib's decoder.

## 5. `@embedFile` or files beside the binary

- `@embedFile(path)` returns a compile-time constant pointer to a fixed-size array holding the file's bytes, as if it were a string literal; the path is relative to the current file, "just like `@import`" ([language reference, @embedFile](https://ziglang.org/documentation/0.16.0/#embedFile)). A file outside the module's directory needs a named import; the POC already does this for the sprite sheet, with `addAnonymousImport("ship_sheet", …)` ([build.zig:78](https://github.com/Holo-Org/R-Type/blob/ca23b7b2b771e0f0340f7d3206aebdbf843fa317/prototypes/lang-zig/build.zig), [sprites.zig](https://github.com/Holo-Org/R-Type/blob/ca23b7b2b771e0f0340f7d3206aebdbf843fa317/prototypes/lang-zig/client/sprites.zig)). The POC's reason: "so that it runs on its own".
- **Embedded**: the Client is a single file, with no path to resolve and no way to forget to ship the sounds; the cost is binary size. The POC's ReleaseSafe Client is 1,274,256 B on macOS and 2,841,600 B as a Windows `.exe` ([REPORT.md, "Binary sizes"](https://github.com/Holo-Org/R-Type/blob/ca23b7b2b771e0f0340f7d3206aebdbf843fa317/prototypes/lang-zig/REPORT.md)). Effects of 10 to 80 KB each add little; a 4 MB music file more than doubles the Windows `.exe` (arithmetic on those figures).
- **Beside the binary**: smaller executable and replaceable sounds, but the Client must find the files whatever the working directory, and the evaluator's copy must include them. The project already plans a lookup "beside the executable, else the OS config folder" for the settings file, so the logic would exist (a team decision not yet written down in this repository).
- **Either way**: the repository holds the files in its history for good. A file added and then removed because of a licence doubt stays in the history. This is the main reason for the CC0-only rule in section 2.
- An embedded OGG or WAV is decoded by the same raylib calls as a file on disk: the file-reading `LoadWave` just reads the file and calls `LoadWaveFromMemory` ([raudio.c:789](https://github.com/raysan5/raylib/blob/6.0/src/raudio.c#L789)). Moving from one to the other later is a small change.
- New Engine work in both cases: a function next to `loadSound` that takes encoded bytes and an extension, for effects and for music, and a pool of aliases for overlapping effects.

## Open points

- **For the team**: generated or asset explosions; music or no music in Part 1; the CC0-only rule; embedded or beside the binary; whether other Players' Ships make a firing sound and a hit sound or only your own (volume of four-Player fire).
- **Unknown**: the project's own licence (decides whether CC BY, CC BY-SA or GPL assets would be acceptable); how any of the named sounds actually sound; whether Freesound's search has a CC0-only filter; the formats and contents of Kenney packs other than Sci-fi Sounds; whether MP3 loops cleanly in raylib; whether the FLAC `config` override works through raylib-zig (not built).
