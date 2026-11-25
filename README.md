# BeverlyHub — RoChess! (v2.0.0)

Hybrid Stockfish 19 VPS + Cloud + Independent Offline Luau Chess Engine with board arrow overlay, live analysis, Dynamic Auto-Adapt Strength, Anti-Engine Turbo, and safe Auto Play.

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/bevankeren/rochess/main/rochess.lua"))()
```

## Highlights (v2.0.0)

- **Hybrid Engine Router**: Stockfish 19 VPS (MultiPV 1/2/3 + speculative ponder preemption) -> Stockfish Cloud fallback -> Independent Offline Luau engine (`PureChess`, `<8s` scramble hardened with in-check qsearch, repetition history, passed-pawn & endgame mop-up eval).
- **Dynamic Auto-Adapt Strength**: Automatically escalates `PlayStyle` against sharp/engine opponents or worse evals and smoothly eases back when comfortably winning.
- **Anti-Engine Turbo & Ponder Prefetch**: Early Suspect + Engine detection from `ply >= 9`, TC-relative clock pressure with hysteresis, 0ms ponder hits even under `<8s`, and fast VIM click mode.
- **Cross-Server Teleport Persistence**: Automatic `queue_on_teleport` reload across cross-server matches with persistent startup attach.
- **Safety & Reliability**: Focus-safe Auto Play (`WindowFocusReleased` pause), self-menu occlusion auto-hide, `AutoGen` race guard, `SaveManager` loading order, and aligned watchdog recovery.
