# Accessibility

What R-Type does for Players with motor, hearing, sight or cognitive disabilities, and what it does not do yet. We started from the basic level of the [Game Accessibility Guidelines](https://gameaccessibilityguidelines.com/basic/), choosing what suits a fast shoot'em up played over the network.

## Motor

- **Every control can be changed.** The Client's `settings.zon` binds each Action (up, down, left, right, fire) to any number of keys and gamepad buttons, and to the left stick. Keys are named after where they sit, so the file works the same on QWERTY and AZERTY keyboards. The file, and where to find it, is described in the [README](introduction.md).
- **Auto-fire.** With `.auto_fire = true`, pressing fire once starts firing and pressing it again stops, so no key needs holding down for a whole Match.
- **No combinations and no quick sequences.** Each Action is one key or button, and no Action needs two at once.
- **Leaving takes two presses.** While a Player's Ship is alive, the first Esc only asks "Press Esc again to leave the Match", so a slip of the hand does not lose the Ship.

## Hearing

- **No sound is the only way to learn something.** Each sound goes with something the screen shows: firing with the Projectile leaving the Ship, an Enemy exploding and a Ship destroyed with their explosions, game over with the game-over screen.
- **What the Client used to say only in its log is now on screen too.** "Player 3 joined", "left" or "timed out" shows at the bottom of the screen for 4 seconds.
- **One volume for every effect.** `.effects_volume`, from 0.0 (silent) to 1.0. There is no music, so there is no second volume to set.

## Sight

- **Ships are never told apart by colour alone.** Each Player's colour comes from the Okabe–Ito palette, which stays distinct under every common form of colour blindness (sky blue, reddish purple, bluish green and orange), and each Ship always has its Player's number beside it. The heart bar lists every Player by number too.
- **Nothing flickers or strobes.** An invulnerable Ship is drawn see-through, steadily, rather than blinking, and no animation alternates frames fast enough to flash.
- **Readable text.** White or light text on the black Star-field, 20 px at the smallest and 30 px for countdowns and questions.
- **Lag can be read, not only felt.** The Client shows its round trip and how much of the Server's traffic was lost in the top-right corner, so a Player can tell a slow network from a slow reaction.

## Cognition

- **Five Actions, nothing else to learn.** There are no menus. A Player starts the Client with the Server's address and plays.
- **The game says what it is waiting for.** "Connecting...", "The Match has already started: waiting for the next one", "Lost the Server: reconnecting...", and a countdown in large type before Waves come and before the next Match.
- **Nothing to read in a hurry.** Notices stay 4 seconds, and nothing asks for an answer under time pressure, apart from the Esc question, which simply goes away after 3 seconds.

## The documentation

- Real headings on every page, so that screen readers can move through them, and a search bar.
- Diagrams are drawn with Mermaid from text, and every diagram is explained by the text around it.
- mdBook's light and dark themes can be picked from the brush icon at the top of each page.

## Not done yet

- Changing controls inside the game: for now, only by editing `settings.zon`.
- Game speed and difficulty settings for Players. The Server can give Ships more hit points and longer invulnerability (`--hit-points`, `--invulnerability`), but a Player cannot choose them.
- Screen reader support in the game itself.
- Resizing the text, or the game's window, beyond what the operating system offers.
