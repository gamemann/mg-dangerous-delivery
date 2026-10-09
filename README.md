This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, players drive loaded trucks up mountain roads with no guard rails, through snow, rain, wind and falling rock, and deliver the load to a depot. The harder the haul, the more it pays, and the money buys bigger trucks and upgrades.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## How it plays
You start in the lot with a box truck and no money. Pick a route, set off, and get the load to the depot at the far end. Every route is a level, and the next level opens once you have delivered on the one below it. Routes are split into stages by checkpoints. Go over the edge and you are put back at the last checkpoint, with some of the load gone.

**The weather belongs to the mountain.** Each route is split into zones, and every couple of minutes each zone rolls its own sky: snow (the road turns white and grip drops to 40%), rain (70% grip), or gusts of wind that push the truck toward the edge. Everybody in a zone gets the same weather. There is also rock falling off the cliffs, black ice, and fallen rock blocking a lane. Each route is cut into a mountain of its own, which climbs behind the cliffs and falls away to a lake under the drop, and the snow lies on it wherever it is snowing on the road.

**Pay** starts from the route's pay, goes up with its level and with the truck you drive (harder trucks pay more), and goes up again for every kind of bad weather and every rockfall you actually drove through. It is scaled by how much of the load arrived, with a bonus for a run with no falls and no skips. The HUD shows what the trip pays right now.

**Money buys trucks and upgrades.** There are five trucks: the Box Truck (free), the Flatbed, the Hauler, the Semi (with an articulated trailer) and the Bulk Carrier. Each one is slower to stop, quicker to slide or longer round a hairpin than the last, and pays more for it. Each has three levels of engine, brakes and tyres.

## Controls

| Key | Action |
| --- | --- |
| **W** / **S** (or arrows) | Accelerate / brake, then reverse once stopped |
| **A** / **D** | Steer |
| **Space** | Handbrake |
| **R** | Back to the last checkpoint (costs what a fall costs) |
| **T** | Restart the trip |
| **N** | Skip a stage (costs part of the pay) |
| **B** | Solo: nobody sees you, nothing of yours collides, and you see nobody |
| **C** | Camera: chase, cab or high |
| **G** / **Esc** | Back to the lot |

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/mg-dangerous-delivery
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/`. `./game.sh shot --help` lists the views |
| `./game.sh help` | All of the options |

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

`tools/drive.sh` has a bot drive every route to the depot.

## Running a server
Console commands:

| Command | |
| --- | --- |
| `dd_status` | What the server is doing |
| `dd_bank` | Everybody's money and deliveries |
| `dd_weather clear\|rain\|snow\|wind\|off` | Force the weather |
| `dd_give <name> <amount>` | Give somebody money |

The quick switches are cvars: `dd_bots`, `dd_solo`, `dd_skip`, `dd_rocks` and `dd_collide`.

Everything else is a setting. Put it in `user://cfg/delivery.json`, or set it with a `DD_*` environment variable or a `--dd-*` argument (the later one wins). The ones you are most likely to change:

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

To change a truck, put it in `user://cfg/delivery_trucks.json` by id, with the same fields as `game/dd_trucks.gd` (for example `{"hauler": {"price": 5000}}`). A new id adds a new truck.

**Where the money is kept.** By default in one JSON file, `user://delivery_accounts.json`. It can also go in SQLite, PostgreSQL or MySQL, in one table called `delivery_accounts` with money and deliveries as columns (so a web panel can sort by them).

## Writing a route

A route is one JSON file in `routes/`, and every one in the directory is a level on the server's map. It is written the way you would describe a road out loud: a list of segments, each a length, a turn and a climb from where the last one ended:

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

The shipped routes are written by `tools/build_routes.py` (`--check` fails if a file is not what it writes).

## Testing

```bash
./game.sh test                  # every script parses, then every suite runs
./game.sh test headless_run     # one suite
tools/drive.sh                  # a bot delivers on every route
```

| Suite | What it covers |
| --- | --- |
| `headless_run` | The game itself: routes, trucks, weather, hazards, pay and the bank |
| `headless_net` | A server and a client in one process, over the network code |
| `dedicated` | A real server: boots, loads the game, runs its commands |

[`CLAUDE.md`](CLAUDE.md) has the design decisions and the reasoning behind them.

## Credits
The trucks are from Kenney's Car Kit and the pines and rocks from Kenney's Nature Kit ([kenney.nl](https://kenney.nl), CC0), in `assets/kenney/` with their licences. Everything else is drawn in code.

## License
MIT. See [LICENSE](LICENSE). The Kenney art is CC0, which is public domain.
