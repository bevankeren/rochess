# BeverlyHub — RoChess! (v2.2.0)

Hybrid Stockfish 19 VPS + Cloud + Independent Offline Luau Chess Engine with dynamic mode-colored board arrows, draggable interactive Tactical HUD & live FYI callouts, Dynamic Auto-Adapt Strength, Anti-Engine Turbo, Auto-Farm Elo (Anti-Rungkat), and safe Auto Play.

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/bevankeren/rochess/main/rochess.lua"))()
```

## Highlights (v2.2.0)

- **Dynamic Mode Colors**: Board arrows and square highlights automatically change color per active engine/mode (Gold on forced Mate, Crimson Red on Turbo, Orange on Auto-Farm Throw, Electric Cyan on Stockfish 19 VPS Full, Emerald Mint on GM Shaper, Purple on Offline Luau, Amber on Fallback). Toggleable inside `Visuals`.
- **Draggable Interactive Tactical Status HUD & Live FYI**: Sleek 2-row floating HUD card (`396x62`) with glowing mode accent strip, pulsing status dot, live Eval Pill, drag-anywhere + double-click reset (auto-hides instantaneously if dragged over an Auto Play target square), and real-time interactive Indonesian FYI alerts (Checkmate otw, Opponent Mate Danger, Blunder Detected, Ponder Hit `0ms`, Critical Only-Move, Draw / 50-Move / Endgame warnings, Clock Drama, Auto-Farm status, and more).
- **Auto-Farm Elo + Anti-Rungkat Guard**: Dedicated `Auto-Farm` tab with persistent cross-teleport state (`farm_state.json`), jittered `+Elo` controlled-loss cycles (`Blunder + Resign`, `Play Weak ~900`, `Late Resign`), `PureChess.pickHumanBlunder` plausible blunder picker, 7 Anti-Rungkat arming guards guaranteeing net-positive Elo, periodic 20-45s human breathers, randomized 3-9s inter-game delays, and optional `Stop At Target Elo` cap.
- **Hybrid Engine Router**: Stockfish 19 VPS (MultiPV 1/2/3 + speculative ponder preemption) -> Stockfish Cloud fallback -> Independent Offline Luau engine (`PureChess`, `<8s` scramble hardened with in-check qsearch, repetition history, passed-pawn & endgame mop-up eval).
- **Dynamic Auto-Adapt Strength**: Automatically escalates `PlayStyle` against sharp/engine opponents or worse evals and smoothly eases back when comfortably winning.
- **Anti-Engine Turbo & Ponder Prefetch**: Early Suspect + Engine detection from `ply >= 9`, TC-relative clock pressure with hysteresis, 0ms ponder hits even under `<8s`, and fast VIM click mode.
- **Cross-Server Teleport Persistence**: Automatic `queue_on_teleport` reload across `RequestedFromServer`/`Started`/`InProgress` teleports with persistent startup attach and farm auto-resume.
- **Safety & Reliability**: Focus-safe Auto Play & Auto-Queue (`WindowFocusReleased` pause), self-menu occlusion auto-hide, `AutoGen` race guard, forced-recalc deadlock fix, `SaveManager` loading order, and aligned watchdog recovery.
