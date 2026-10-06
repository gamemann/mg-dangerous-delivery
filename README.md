# Dangerous Delivery

Drive a loaded truck up mountain roads with no rails, through snow, rain, wind and falling rock, and deliver it. The harder the haul, the more it pays.

A minigame for the TMC platform, built on the dot-* addons ([dot-vehicle](https://github.com/modcommunity/dot-vehicle) drives every truck).

## Playing

You start in the lot with a box truck and no money. Pick a route, set off, and get the load to the depot at the far end. Every route is a level: the next one opens when you have delivered one of the level below. A route is split into stages by checkpoints; go over the edge and you are put back on the last one you reached, with some of the load gone.

| Key | |
| --- | --- |
| W / S, arrows | Accelerate; brake, then reverse once stopped |
| A / D | Steer |
| Space | Handbrake |
| R | Back to the last checkpoint (costs what a fall costs) |
| T | Restart the trip |
| N | Skip a stage (costs part of the pay) |
| B | Solo: nobody sees you and nothing of yours collides, and you see nobody |
| C | Camera: chase, cab, high |
| G / Escape | Back to the lot |

**What a trip pays** is the route's pay, raised for its level, multiplied by the truck's pay (harder trucks pay more), raised for every kind of bad weather and every rockfall you actually drove through, scaled by how much of the load arrived, and with a bonus for a run with no falls and no skips. The lot shows each route's starting pay; the HUD shows what the trip pays right now.

**Money buys trucks and upgrades.** Four trucks — Box Truck (free), Flatbed, Hauler, Bulk Carrier — each slower to stop, quicker to slide or longer round a hairpin than the last, and paying more for it. Each has three levels of engine, brakes and tyres.

**Hazards**: rock that comes off the cliff ahead of you, black ice, and fallen rock blocking a lane.

**Weather is the mountain's, not yours.** Every route has zones, and each zone draws its own sky every couple of minutes: snow (the road turns white and grip drops to 40%), rain (70%), and wind that comes in gusts and pushes the truck toward the edge. Everybody on a zone has the same sky.

## Running a server

The game is a dot-server pack: `scenes/dd_server.tscn` is the world, `game/dd_module.gd` the module (see `game.yml`). Console commands: `dd_status`, `dd_bank`, `dd_weather clear|rain|snow|wind|off`, `dd_give <name> <amount>`; cvars `dd_bots`, `dd_solo`, `dd_skip`, `dd_rocks`, `dd_collide`.

Every rule is a setting, layered like everything in the family: defaults < `user://cfg/delivery.json` < `DD_*` environment < `--dd-*` command line. The ones an owner most often changes:

| Setting | Default | |
| --- | --- | --- |
| `snow_grip`, `rain_grip` | 0.4, 0.7 | Grip on snow and in rain |
| `wind_strength` | 2.6 | Peak side push, m/s² |
| `weather_frequency` | 1.0 | Multiplies every zone's chances; 0 is clear skies |
| `boulders_enabled`, `boulder_chance` | true, 0.7 | Falling rock |
| `ice_grip` | 0.3 | Grip on black ice |
| `fall_cargo_loss` | 0.15 | Load lost per fall |
| `level_pay_step`, `chaos_pay`, `clean_run_bonus` | 0.35, 0.6, 0.25 | The pay formula |
| `allow_solo`, `solo_hidden_from_others` | true, true | Solo mode |
| `trucks_collide` | true | Whether trucks hit each other at all |
| `allow_skip`, `skip_cost_fraction`, `allow_restart` | true, 0.25, true | The buttons |
| `levels_unlock_in_order` | true | Routes open level by level |
| `starting_money` | 0 | |

Trucks are overridden from `user://cfg/delivery_trucks.json`, keyed by truck id with the same fields as `game/dd_trucks.gd` (`{"hauler": {"price": 5000}}`); a new id adds a truck.

**Where the money is kept.** By default one JSON file, `user://delivery_accounts.json`. For SQLite, PostgreSQL or MySQL the bank takes any driver with dot-moderation's shape (`execute`, `query`, `dialect`) and keeps one table, `delivery_accounts`, with money and deliveries as columns a web panel can sort by.

## Writing a route

A route is one JSON file in `routes/`, and every one in the directory is a level on the server's map. It is written the way you would describe a road out loud — a list of segments, each a length, a turn and a climb from where the last one ended:

```json
{
	"format": 1, "kind": "route", "id": "my_pass", "name": "My Pass", "author": "you",
	"blurb": "One line for the lot.", "level": 2, "pay": 400, "width": 7.5,
	"zones": {"top": {"name": "The Top", "snow": 0.8, "rain": 0.0, "wind": 0.3}},
	"segments": [
		{"length": 80},
		{"length": 140, "turn": -35, "climb": 10, "wall": "left"},
		{"length": 95, "turn": 180, "climb": 6, "wall": "right", "zone": "top", "checkpoint": true},
		{"length": 120, "climb": 12, "wall": "none", "zone": "top", "boulders": 2, "width": 6.5}
	]
}
```

Lengths are metres and angles degrees (positive turns right). `climb` is a segment's whole rise. `wall` is the side the cliff is on (`left`, `right`, `both`, `none`); the other side is the drop. `rail` puts a low barrier on a side. `checkpoint` ends a stage at the end of that segment. `boulders` is how many places along it rock can come down. `ice` lays that many patches of black ice (slippery in any weather, drawn as a pale sheet); `debris` that many piles of fallen rock, each blocking one lane. A bend tighter than a truck can take, or a climb steeper than 18%, is refused with the reason.

The shipped routes are written by `tools/build_routes.py` (`--check` fails if a file is not what it writes), and `tools/drive.sh` has a stand-in drive every route to the depot.

## Checking it

```bash
godot --headless --path . --import
godot --headless --path . res://examples/headless_run.tscn   # 14 sections, 79 checks
godot --headless --path . res://examples/headless_net.tscn   # a server and a client, 30 checks
godot --headless --path . res://examples/dedicated.tscn      # a real server and the module, 19 checks
tools/drive.sh                                                # a stand-in delivers every route
tools/shot.sh --view=drive --route=dd_snowline --sky=snow     # look at it
```

## Credits

- Truck models: [Kenney](https://kenney.nl) Car Kit, CC0 1.0 (`assets/kenney/trucks/`, licence beside them).
- Everything else is drawn in code.

MIT licence; see [LICENSE](LICENSE).
