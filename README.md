# Secret Word

A party game for 3–8 players in the same room, each on their own phone, built with [Defold](https://defold.com).

Everyone gets the same secret word, except the **impostor**, who only knows the category. Players take turns saying one clue out loud, argue about who's faking it, and vote. Catch the impostor and they still get one last guess at the word to steal the round.

The phones deal the cards, run the timers, collect the votes and keep score. The talking happens in the room.

## How it started

The project began as an experiment with **local multiplayer lobbies in Defold**: can a few phones find each other on the same Wi-Fi or phone hotspot and play together, without any internet or server? The test grew from a bare lobby, through a "tap and everyone sees it" demo, into a complete game that shows what the lobby system can do.

## How a round plays

1. **Secret card:** hold to reveal your card. Players see the category and the word, and the impostor sees only the category.
2. **Clues:** in the order shown, everyone says one word out loud and taps *Done* before the clue timer runs out. The impostor never goes first.
3. **Discuss:** phones down, talk it out. Players can mark themselves ready to vote early.
4. **Vote:** a secret vote for anyone but yourself.
5. **Result:**
   - **Impostor gets the most votes:** they're caught, but get one last guess at the word. A correct guess steals the round.
   - **An innocent player gets the most votes, or the vote is tied:** the impostor escapes.

**Scoring:** +1 to everyone who voted for the impostor, and +2 or +3 to the impostor when they win the round. The highest score after the last round wins.

**Host settings:** before starting, the host can choose the number of rounds (3–6), the time per clue (15–45 s) and the discussion time (30 s – 5 min).

## How the multiplayer works

- **Offline, host-authoritative:** one phone hosts and runs the game rules. The others connect to it over the local network (Wi-Fi, or the host phone's hotspot).
- **Discovery without broadcast:** clients find hosts by sending a small UDP probe to every address in their subnet. That works on Android and iOS without the multicast permissions that broadcast discovery needs.
- **Messages:** JSON lines over TCP, with heartbeats and disconnect detection. Players who leave or lose connection are announced to everyone.
- **Private views:** after every change, the host sends each player a snapshot of only what that player may see. The impostor's phone never receives the word.
- **Ports:** TCP 47800 (game) and UDP 47801 (discovery). On a desktop host, allow them through the firewall.

## Running it

**Requirements:** Defold **1.13.1**. The editor, CI and project are all pinned to this version.

- **Desktop:** open the project in the Defold editor and press **Ctrl+B**. The window is tall (780×1688, twice the phone design size), so resize it as needed.
- **Android, quickest:** install the Defold dev app, choose your phone under *Project → Target*, and press Ctrl+B. The project has no native extensions, so the standard dev app works.
- **Android, as an app:** *Project → Bundle → Android Application*, then install the APK with `adb install`.
- **Testing multiplayer:** you need at least 3 players. Any mix works, for example the editor on your PC plus two phones on the same Wi-Fi.

## Releases

Pushing a tag like `v1.2.3` runs the [Android Release workflow](.github/workflows/android-release.yml). It builds a release APK with Bob, stamps the version from the tag, signs it with the keystore from the repository secrets, and publishes it as a GitHub Release.

## Debug tools

**Screen gallery.** In debug builds, the menu has a **Screens** link. It steps through every screen with sample data, so you can review layouts without setting up a game. It covers 8 players, long names, every outcome, and the popups.
- Prev/Next or ←/→ switch screens, and tapping the title or pressing Esc exits.
- Every page is checked with the real fonts. Overlapping or off-screen text is highlighted in red, and the top bar shows the number of issues.

**Automatic layout check.** Start a debug build with the environment variable `SECRET_WORD_LAYOUT_CHECK` set to a file path. The game checks every gallery page, writes a report to that file and exits, with exit code 1 if any page has layout problems.

## Project layout

| Path | What's in it |
|---|---|
| `net/lobby_net.lua` | Local networking: hosting, discovery, joining, heartbeats, messages |
| `game/secret_word.lua` | The game rules, settings and scoring (runs on the host only) |
| `game/screens.lua` | The in-game screens, one per phase |
| `game/words.lua` | Categories and secret words |
| `lobby/lobby.gui_script` | Menu (name entry), finding games, lobby and settings popup; wires everything together |
| `ui/ui.lua` | GUI helpers, theme colours, text measuring and the layout check |
| `debug/gallery.lua` | The screen gallery and the automatic layout check |
| `fonts/`, `ui/images/` | Fonts and the rounded-corner textures for the UI |

## Credits

- Fonts: [Bricolage Grotesque](https://fonts.google.com/specimen/Bricolage+Grotesque) and [DM Sans](https://fonts.google.com/specimen/DM+Sans), both under the SIL Open Font License.
- Built with the [Defold](https://defold.com) game engine.
