# mg-dangerous-delivery

Drive a loaded truck up mountain roads with no rails, through weather and falling rock, and deliver it. Levels are routes; harder trucks and worse weather pay more; money buys trucks and upgrades.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and dot-vehicle's `CLAUDE.md` before touching how a truck drives. This file is only about what this game decides.

**Built 2026-10-06, in one session, offline-first.** The world, the routes, the trucks, the bank, the garage, the HUD and the client are here and playable (`godot --path .`); the networked half (a `DotGameModule`, a bridge, a client mirror) is not, and is the first thing on the list below.

## What this game is, versus the others

Every other game in the family puts a person on foot. This one has nobody walking: **a player is their truck**, from the lot to the depot. So dot-vehicle's seat handover (`DotVehicleRide`, the spawner) is not used — `DdTruck` binds a `DotVehicleInstance` and a `DotVehicleWheeled` chassis itself and `DdGame` calls `drive()` once a tick, the same call the spawner makes.

## Layout

```
game/
  dd_config.gd     every rule, as a DotConfig (DD_*, --dd-*). Every gameplay number is here
  dd_route_doc.gd  what a route IS: segments (length, turn, climb, wall, rail, zone, checkpoint, boulders); validated
  dd_route.gd      a document built: sampled every 2 m, the road/slab/cliff/skirt meshes, one trimesh, gates, pads; every query
  dd_weather.gd    the sky over a zone as a pure function of (seed, zone, tick); gusts; grip
  dd_trucks.gd     the catalogue and the upgrades, as data; tunables_for() is what a truck drives with
  dd_truck.gd      a VehicleBody3D built from a Kenney model: hull from its bounds, wheels from its wheel nodes
  dd_trip.gd       one haul: stage, cargo, falls, skips, the chaos it met, and the pay formula
  dd_bank.gd       accounts, and two stores: JsonStore and SqlStore (dot-moderation's driver shape)
  dd_game.gd       the world: every route side by side, drivers, trips, falls, rock, solo, stand-ins, garage_view()
  dd_hud.gd        the stage strip, the numbers, the keys, a message line
  dd_garage.gd     the lot: routes, trucks, upgrades; asks through a callable and is told
  dd_client.gd     one player offline: camera (chase/cab/high), controls, weather particles, visibility
  dd_paths.gd      mount-aware paths (mg-deathrun's DrPaths)
routes/            five routes, written by tools/build_routes.py
assets/kenney/trucks/  four Car Kit trucks and their atlas, CC0
examples/          headless_run (13 sections, 72 checks)
tools/             build_routes.py; drive.sh/.gd (a stand-in delivers every route); shot.sh/.gd (render)
```

## Decision 1: one world holds every route, and a route is a level

The brief asked for a big map whose corners have their own weather, and for levels that get harder. Both are this: `DdGame.build_routes` lays every document side by side along +X (`ROUTE_GAP` apart), each route is a level by its document's `level`, and each has its own zones. A player picks a route in the lot. A server owner's new route is a file in `routes/` and a new corner of the map. `levels_unlock_in_order` opens level N once any route of level N-1 is delivered (or the nearest level below if one is missing).

## Decision 2: weather is the world's, and what a trip is paid for is measured

Several trucks share a mountain, so the sky over a zone is `DdWeather.at(seed, "route|zone", zone, tick)` — a hash per `PERIOD_SECONDS` (150) window — and is the same for everybody on it. **Not `hash()`:** Godot's string hash is djb2 and strings differing in their last character differ only in its low bits, so every period of a zone rolled 0.2816 to 0.2819 and a 50% zone was snowy always or never. `DdWeather.unit()` takes MD5's first 32 bits. Boulder rolls use it too.

A trip's chaos is counted from what it met (`DdTrip.meet`: each zone's sky and wind once; each rock site once), because a bonus for a blizzard nobody drove through is a bonus for nothing. Snow paints a zone's road material white (`DdRoute.paint_zone`) on every machine from the same function. `DdGame.force_weather(sky, wind)` overrides every zone, including road no zone names — an operator's tool and the screenshot tool's.

## Decision 3: falls are a height test, rock is rate-limited

Off the mountain is `truck.y < road height at the nearest sample - fall_depth`, not a trigger volume (mg-smash-copter's reason: something falling fast steps over a volume). Flipped and still for `flipped_respawn_seconds` is a fall too. A fall costs `fall_cargo_loss` and puts the truck on its last checkpoint after `respawn_seconds`; R (respawn) costs the same, or a player about to go over would press it for free. A truck put down is a **ghost** to other trucks for `GHOST_SECONDS`, so two put on one checkpoint do not explode apart.

A rock site comes down when a driving truck is `boulder_trigger_distance` short of it, on `boulder_chance`, and then not again for `boulder_cooldown_seconds` (60): at 20 s a slow truck sent back to the start was met by the same rock every time it set off and fell eleven times in a row. Rock starts above the cliff top: at 9 m up it started behind a 16 m face and the cliff caught it.

## Decision 4: solo is collision exceptions and visibility

`DdGame._refresh_exceptions` makes every pair of trucks collide unless either is solo, either is a ghost, or `trucks_collide` is off — both ways, recomputed whenever a truck appears, goes, or changes. `DdGame.sees(viewer, other)`: a solo viewer sees nobody; a solo truck is hidden from others unless `solo_hidden_from_others` is off (a truck others can see and drive through is a ghost, which is worse than one that is not there). Chat is not touched by it.

## What running and rendering found

- **The road had no collision.** `PackedVector3Array` is copy-on-write in GDScript: the faces appended in a helper went into a copy, and the first truck fell from the start line.
- **The road surface was culled.** Godot's front face is clockwise; the quads were written counter-clockwise, and the first render showed the cream underside of the slab through the road.
- **The garage and the HUD were zero-sized in the top-left**: `set_anchors_preset` without offsets, under a CanvasLayer.
- **Hairpins had the drop on the inside**, where every truck cuts the corner; a stand-in fell 41 times in one bend. `build_routes.py`'s `hairpin()` puts the cliff inside, always.
- **A scene with a parse error hangs** (the family's rule): `tools/drive.gd` with `:=` on an untyped receiver ran until its timeout.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"; done
godot --headless --path . res://examples/headless_run.tscn   # 13 sections, 72 checks, ~25 s
tools/build_routes.py --check
tools/drive.sh                     # every route delivered by a stand-in; TRUCK=bulk too (2026-10-06)
tools/shot.sh; tools/shot.sh --view=drive --route=dd_snowline --sky=snow --seconds=45
```

The suite's checks and sections were both armed by being wrong (74 declared, 72 ran; it fired).

## Still to do

In the order they are worth doing.

1. **Networking.** A `DotGameModule` (mg-deathrun's is the closest skeleton), a bridge that sends the route documents and the seed once and the trucks' transforms per snapshot (dot-vehicle's `DotVehicleNetSync`, interpolated, not predicted), requests for the garage (start, buy, select, upgrade, skip, restart, respawn, solo) answered by `DdGame`, and a client that mirrors instead of owning the world. Chat, voice and moderation through `DotGameServices`; the bank's store from the server's config (JSON or a dot-moderation SQL driver). `game.yml`, `scenes/dd_server.tscn`, a dedicated suite.
2. **dot-stats**: deliveries, distance, falls, money earned, per player, reported like mg-deathrun's `DrProgress`.
3. **Scenery.** The mountain is the road and its cliff; there is no terrain beyond, and the other routes show as pale walls in the distance. Kenney's Nature Kit has rocks and trees.
4. **A trailer.** The brief says 18-wheelers; Kenney has none, and an articulated trailer on a `Generic6DOFJoint3D` is a real physics job (jack-knifing is the point of it).
5. **Sounds**: engine, brakes, a boulder, the depot.
6. **The GitHub repository** (gamemann/mg-dangerous-delivery) is the owner's to create; the remote is set and nothing is pushed.
