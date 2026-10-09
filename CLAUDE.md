# mg-dangerous-delivery

Drive a loaded truck up mountain roads with no rails, through weather and falling rock, and deliver it. Levels are routes; harder trucks and worse weather pay more; money buys trucks and upgrades.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and dot-vehicle's `CLAUDE.md` before touching how a truck drives. This file is only about what this game decides.

**Built 2026-10-06, in one session.** Offline first (the world, routes, trucks, bank, garage, HUD, client; `godot --path .`), then the networked half the same day: a `DotGameModule`, a bridge, a mirroring client, and a dedicated suite against a real `DotServer`. Joined by a real client over a real socket in a delivered pack (dot-server-deploy's `examples/delivery_client`, 18 checks); not yet seen in a browser, and not published: see the list at the bottom.

## What this game is, versus the others

Every other game in the family puts a person on foot. This one has nobody walking: **a player is their truck**, from the lot to the depot. So dot-vehicle's seat handover (`DotVehicleRide`, the spawner) is not used — `DdTruck` binds a `DotVehicleInstance` and a `DotVehicleWheeled` chassis itself and `DdGame` calls `drive()` once a tick, the same call the spawner makes.

## Layout

```
game/
  dd_config.gd     every rule, as a DotConfig (DD_*, --dd-*). Every gameplay number is here
  dd_route_doc.gd  what a route IS: segments (length, turn, climb, wall, rail, zone, checkpoint, boulders); validated
  dd_route.gd      a document built: sampled every 2 m, the road/slab/cliff/cliff-top/drop-strip meshes, one trimesh, gates, pads; every query
  dd_terrain.gd    the mountain under a route: one heightfield from the samples, held under the road by a band; drawn only, per-zone snow
  dd_weather.gd    the sky over a zone as a pure function of (seed, zone, tick); gusts; grip
  dd_trucks.gd     the catalogue and the upgrades, as data; tunables_for() is what a truck drives with
  dd_truck.gd      a VehicleBody3D built from a Kenney model: hull from its bounds, wheels from its wheel nodes
  dd_trailer.gd    the Semi's trailer: a VehicleBody3D on free wheels, a Generic6DOF hitch, re-hitched on every teleport
  dd_trip.gd       one haul: stage, cargo, falls, skips, the chaos it met, and the pay formula
  dd_bank.gd       accounts, and two stores: JsonStore and SqlStore (dot-moderation's driver shape)
  dd_game.gd       the world: every route side by side, drivers, trips, falls, rock, solo, stand-ins, garage_view()
  dd_hud.gd        the stage strip, the numbers, the keys, a message line
  dd_garage.gd     the lot: routes, trucks, upgrades; asks through a callable and is told
  dd_client.gd     one player: offline it owns the world, connected it mirrors one; camera, controls, particles, visibility
  dd_module.gd     the DotGameModule: netcode numbers, cvars (dd_bots, dd_solo, dd_skip, dd_rocks, dd_collide), dd_status/dd_bank/dd_weather/dd_give, stand-ins, the bank's store
  dd_services.gd   chat (all, admin, whisper), push-to-talk voice, moderation, over dot-game's base
  dd_client_chat.gd  the chat box (Y) and push-to-talk (V); a truck idles while its driver types
  dd_sounds.gd     synthesised: a diesel whose pitch follows speed, brake hiss, rain, wind, rock, the depot chime; a positional engine on every other truck (heard to 60 m, silent when that truck is hidden)
  dd_progress.gd   dot-stats numbers and achievements, reported to the backbone
  dd_server.gd     what scenes/dd_server.tscn runs: the world, drawing nothing
  dd_paths.gd      mount-aware paths (mg-deathrun's DrPaths)
  net/             dd_events (kinds; JSON bodies; the 4-byte drive), dd_event/dd_request, dd_net_link (copied), dd_body_net / dd_truck_net (pose, steering, speed), dd_net_bridge
routes/            five routes, written by tools/build_routes.py
assets/kenney/trucks/  four Car Kit trucks and their atlas, CC0
scenes/            dd_server.tscn
examples/          headless_run (16 sections, 89 checks), headless_net (10, 33), dedicated (6, 19)
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

**Black ice and debris are part of the road, not the weather.** A segment's `ice` and `debris` counts are laid by `DdRoute._place_hazards` from `DdWeather.unit()` of the route, segment and index, so every machine lays the same ones; ice drops grip to `ice_grip` and is paid once as `ice_chaos`, and a debris pile takes one lane and never both, because a pile across the whole road is a road nobody can drive. `route_points` swings a stand-in into the other lane round a pile.

## Decision 4: solo is collision exceptions and visibility

`DdGame._refresh_exceptions` makes every pair of trucks collide unless either is solo, either is a ghost, or `trucks_collide` is off — both ways, recomputed whenever a truck appears, goes, or changes. `DdGame.sees(viewer, other)`: a solo viewer sees nobody; a solo truck is hidden from others unless `solo_hidden_from_others` is off (a truck others can see and drive through is a ghost, which is worse than one that is not there). Chat is not touched by it.

## Decision 4b: the Semi pulls a trailer, on a joint

The brief says eighteen-wheelers. The Semi (`DdTrucks`, `"trailer": {length, mass}` on any truck makes one) pulls a `DdTrailer`: a VehicleBody3D on four free-rolling wheels — a box dragged along the road is friction that stops a truck dead on a climb — hitched by a `Generic6DOFJoint3D` that swings ±80°, nods ±18° and rolls hardly at all (a trailer that could roll on its own would leave the road while the truck stayed on it). It takes the road's grip, it is in every collision exception its truck is (solo, ghost), it is replicated as its own body, and **every teleport re-hitches it** (`DdTrailer.rehitch`): a joint whose two bodies jumped apart yanks them back together, which the screenshot tool found by doing exactly that — the truck dragged back to its trailer at the lot, 43% of the load gone. `trailers` (on) turns them all off. A stand-in delivers every route in the Semi (`TRUCK=semi tools/drive.sh`).

## Decision 5: the wire carries trucks in snapshots and everything else as JSON

Nothing is predicted (dot-vehicle's decision for rigid bodies), so the bridge is a fraction of the other games'. A client sends what it is pressing as four bytes a tick behind a snapshot ack (`DdEvents.write_drive`), unreliably; the server drives with the latest. Trucks and boulders are `DotNetIdentity`s with `Authority.SERVER`, always relevant, replicated by `DdBodyNet` (pose, interpolated) and `DdTruckNet` (plus steering and signed km/h); a client creates the body on a DRIVER or BODY event and keeps it frozen. HELLO carries the seed, the route documents and the settings a client's own weather needs; after that a client builds every road and computes every zone's sky itself, and `headless_net` checks the nine zones agree. The rest — DRIVER, GONE, TRIP (to the owner, six a second), GARAGE, SAY, WEATHER, BODY — is JSON, because it is a few hundred bytes a second and a garage view that grows a field should be a change in one place. Every garage button and key is one ACT request answered by `DdBridgeActs.run`, which an offline client calls directly: one table, so offline and online cannot mean different things by "skip".

**Names are the site's**: `DdModule._make_identity` is dot-platform's `DotPlatformIdentity` with no avatar schema (nobody is drawn; a player is their truck), and since admission finishes after the seat, `player_admitted` and `player_renamed` end in `DdNetBridge.rename`, a DRIVER again. Money is keyed by the session's account uid (`uid:…`), which dot-server has at connect; the platform's profile arrives after seating, too late to key by. The bank's store is `DdModule.bank_file` (JSON) unless a host sets `DdModule.bank_driver` to a dot-moderation SQL driver.

## What running and rendering found

- **The road had no collision.** `PackedVector3Array` is copy-on-write in GDScript: the faces appended in a helper went into a copy, and the first truck fell from the start line.
- **The road surface was culled.** Godot's front face is clockwise; the quads were written counter-clockwise, and the first render showed the cream underside of the slab through the road.
- **The garage and the HUD were zero-sized in the top-left**: `set_anchors_preset` without offsets, under a CanvasLayer.
- **Hairpins had the drop on the inside**, where every truck cuts the corner; a stand-in fell 41 times in one bend. `build_routes.py`'s `hairpin()` puts the cliff inside, always.
- **Two stand-ins put on one start line jammed** at full throttle (2 m in 4 s, found by `dedicated`): their ghost time ran out while they still overlapped. A ghost now lasts until it is clear of every other truck.
- **A scene with a parse error hangs** (the family's rule): `tools/drive.gd` with `:=` on an untyped receiver ran until its timeout.

## Decision 6: the mountain is a heightfield held under the road by a band

`DdTerrain` (2026-10-08) is one grid per route (5 m cells, 110 m past the road, ~20k vertices, ~0.25 s to build), computed from the samples alone, so every client raises the same mountain and a server raises none (`draws`; nothing collides with it, and the road's trimesh stays the only thing a truck stands on). Each vertex finds its nearest sample by two chamfer sweeps, and the nearest sample on another stretch of road (more than 40 samples away) by two more; it asks each what it wants (cliff side: the wall top plus a ridge that climbs 55 m and comes down past 45 m; drop side: the drop's slope, 1 m under the drop strip, to the water) and blends the two by inverse distance cubed. Then three blurs, hashed value noise (`DdWeather.unit`, never `hash()`) away from the road, a fall to the water at the grid's edge, a bank under the lot and the depot, and **last, the band**: every vertex within `BAND` (8 m) of any sample's road edge, or of a pad, is held under that slab. 8 m is more than a cell's diagonal, so a triangle with any vertex outside the band has no point over the road — which is the whole argument, and `headless_run`'s "the mountain" asks it of the drawn triangles (`height_at`) at every half metre across every road on every route.

The band leaves a trench behind each wall, so the wall gets a **cliff top** (`DdRoute._cap`): a strip from its top edge 13 m back, climbing, with a face down its far side and closed ends; the mountain rises through it. The drop's rock strip now runs 13 m out (`DROP_STRIP`) and the terrain carries the same slope on. Snow is a shader: per-vertex zones blended over 40 m of road, `paint_zone` sets each zone's snow and wet, and ground above 112 m keeps its snow. Pines and rocks on the mountain are one hashed candidate per 3x3 cells, standing at `height_at` of their own spot; the drop's pines stand on whichever of strip and terrain is there.

What rendering found, in order (`tools/shot.sh`, none of it visible to a suite):

- **The mountain ran on behind the lot** to the grid's edge and stood there as a block with a dark cliff face; it now gives way over 45 m past either end of the road.
- **Every route stood in the lake on a 60 m cliff of its own** at an 80 m margin; at 110 m (neighbours' grids may overlap, never reaching another road) and a 60 m fall it reads as a massif.
- **The lot and the depot floated** at the shore once the mountain gave way there: hence the banks.
- **A cliff top's open end** was a thin fin against the sky.
- **The mountain began 20 m before its wall**, on the drop side, when the wall was dilated before smoothing: a hillside with no collision under it, which a truck going over would have fallen through. The taper is now inside the wall's own stretch (eroded, then smoothed).
- **The 38 m drop strip ended in a lip** 2.5 m over the terrain, shaded unlike it; it is 13 m now, with the terrain 1 m under its plane. (A dark arch beside Devil's Spine's depot, seen from above, outlived that change: it is the massif's edge steepening into the lake, 50 m from the road, and was left.)
- **Casting shadows, the mountain cost a fifth of a software-rendered frame** (a 10 s drive render: 56 s against 46 s without it); off, 47 s.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"; done
godot --headless --path . res://examples/headless_run.tscn   # 16 sections, 89 checks, ~35 s
godot --headless --path . res://examples/headless_net.tscn   # 10 sections, 33 checks: server and client over loopback
godot --headless --path . res://examples/dedicated.tscn      # 6 sections, 19 checks: a real DotServer and the module by path
tools/build_routes.py --check
tools/drive.sh                     # every route delivered by a stand-in; TRUCK=bulk too (2026-10-06)
tools/shot.sh; tools/shot.sh --view=drive --route=dd_snowline --sky=snow --seconds=45
```

Each suite's check total was armed by being wrong once (headless_run 74/72, headless_net 31/30, dedicated 20/19; all fired; headless_run again at 89/88 when "the mountain" was added, and its road check by narrowing `DdTerrain.BAND` to 2 m, which put ground through 8772 points of road).

## Still to do

In the order they are worth doing.

1. **A browser look.** `examples/delivery_client` in dot-server-deploy proves the pack, the socket and the driving; nobody has driven it in the web shell. Then publish: the pack is `tmc/delivery` (`content/delivery/`), and the release order is the family's (addons tagged, shell, then the game).
2. **The mountain, further.** Built (Decision 6). Left: from above each route is still its own island in the lake, with the massif's edge a steep face down to the water; one terrain under the whole world would join them, at the cost of the per-route build. The build is ~1.3 s for five routes on this machine and has not been timed in a browser. Grid lines on the steepest faces show at 5 m cells.
3. **The GitHub repository** (gamemann/mg-dangerous-delivery) is the owner's to create; the remote is set and nothing is pushed.
