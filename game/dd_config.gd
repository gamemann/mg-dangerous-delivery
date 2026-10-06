extends DotConfig

## Every rule a haul is played under. The routes themselves are documents (`routes/`), the
## trucks a catalogue (`DdTrucks`); this is everything else, layered like every DotConfig in
## the family: exported defaults < JSON file < DD_* environment < --dd-* command line.
##
## [b]Every gameplay decision is a number here, on purpose.[/b] What pays how much, how
## slippery snow is, whether a fall costs money, whether solo players are hidden — each is a
## server owner's call about the server they want, and a constant in code is a decision
## taken away from them.

# --- Trips -----------------------------------------------------------------

@export_group("Trips")

## Seconds the truck is held at the start of a trip, so a player can see the road first.
@export_range(0.0, 30.0, 0.5) var start_hold_seconds: float = 3.0

## Metres below the road a truck has fallen before it counts as off the mountain.
@export_range(5.0, 200.0, 1.0) var fall_depth: float = 18.0

## Seconds after a fall before the truck is put back on the last checkpoint.
@export_range(0.0, 10.0, 0.25) var respawn_seconds: float = 1.5

## Fraction of the cargo lost on each fall. 0 makes a fall cost only time.
@export_range(0.0, 1.0, 0.05) var fall_cargo_loss: float = 0.15

## Whether a player may skip the stage they are on. The genre offers it; a server that
## thinks it cheapens the haul turns it off.
@export var allow_skip: bool = true

## What skipping a stage costs, as a fraction of the trip's pay. Paid at the end.
@export_range(0.0, 1.0, 0.05) var skip_cost_fraction: float = 0.25

## Whether a player may restart the whole trip from the lot.
@export var allow_restart: bool = true

## Seconds a truck may sit still on its back or side before it is put back on the road.
@export_range(1.0, 30.0, 0.5) var flipped_respawn_seconds: float = 4.0

## Whether a route is locked until the one before it (by level) has been delivered.
@export var levels_unlock_in_order: bool = true

# --- Pay -------------------------------------------------------------------

@export_group("Pay")

## Money a new player starts with.
@export_range(0, 1000000, 10) var starting_money: int = 0

## Pay multiplier per route level above 1: a level 4 route pays (1 + 3 * this) of its base.
@export_range(0.0, 5.0, 0.05) var level_pay_step: float = 0.35

## Extra pay per unit of chaos (see [method DdTrip.chaos]): bad weather and falling rock.
## 1.0 doubles the pay of a trip with one unit of chaos in it.
@export_range(0.0, 5.0, 0.05) var chaos_pay: float = 0.6

## Whether damaged cargo pays less. Off pays the full amount for whatever arrives.
@export var cargo_condition_pays: bool = true

## The least fraction of the pay a delivered trip earns however wrecked its cargo is.
@export_range(0.0, 1.0, 0.05) var minimum_pay_fraction: float = 0.2

## Bonus fraction for a trip with no falls.
@export_range(0.0, 5.0, 0.05) var clean_run_bonus: float = 0.25

# --- Cargo -----------------------------------------------------------------

@export_group("Cargo")

## Change of speed in one tick, in m/s, that counts as a knock to the cargo.
@export_range(0.5, 50.0, 0.5) var knock_threshold: float = 4.0

## Cargo lost per m/s of a knock above the threshold, as a fraction.
@export_range(0.0, 1.0, 0.005) var knock_loss_per_speed: float = 0.02

# --- Weather ---------------------------------------------------------------

@export_group("Weather")

## Grip multiplier on snow. The road is drawn white wherever this applies.
@export_range(0.05, 1.0, 0.01) var snow_grip: float = 0.4

## Grip multiplier in rain.
@export_range(0.05, 1.0, 0.01) var rain_grip: float = 0.7

## Peak side force of wind, as metres per second squared on the truck. Gusts are a pure
## function of the tick, so every machine agrees about them.
@export_range(0.0, 20.0, 0.1) var wind_strength: float = 2.6

## Chaos a snowy zone adds to a trip ([member chaos_pay]).
@export_range(0.0, 3.0, 0.05) var snow_chaos: float = 0.5

## Chaos a rainy zone adds.
@export_range(0.0, 3.0, 0.05) var rain_chaos: float = 0.25

## Chaos a windy zone adds.
@export_range(0.0, 3.0, 0.05) var wind_chaos: float = 0.3

## Grip on black ice, whatever the sky.
@export_range(0.05, 1.0, 0.01) var ice_grip: float = 0.3

## Chaos a trip that crossed black ice is paid for, once.
@export_range(0.0, 3.0, 0.05) var ice_chaos: float = 0.2

## Multiplies every zone's own chance of each weather. 0 is a server of clear skies.
@export_range(0.0, 3.0, 0.05) var weather_frequency: float = 1.0

# --- Hazards ---------------------------------------------------------------

@export_group("Hazards")

## Whether falling rock is on at all.
@export var boulders_enabled: bool = true

## Chance each boulder a route places actually comes down on a given trip.
@export_range(0.0, 1.0, 0.05) var boulder_chance: float = 0.7

## Metres ahead of a truck a boulder is set rolling.
@export_range(10.0, 200.0, 1.0) var boulder_trigger_distance: float = 55.0

## A boulder's radius in metres.
@export_range(0.3, 5.0, 0.1) var boulder_radius: float = 1.4

## A boulder's mass in kilograms. Heavy enough to shove a box truck, not to throw a hauler.
@export_range(100.0, 50000.0, 100.0) var boulder_mass: float = 3500.0

## Speed a boulder is thrown across the road at, m/s.
@export_range(0.0, 40.0, 0.5) var boulder_speed: float = 11.0

## Seconds before one stretch of cliff can drop again. Long, because a truck put back on the
## checkpoint before it would otherwise be met by rock every time it set off again.
@export_range(5.0, 600.0, 5.0) var boulder_cooldown_seconds: float = 60.0

## Chaos each boulder that comes down adds, once per stretch of cliff per trip.
@export_range(0.0, 3.0, 0.05) var boulder_chaos: float = 0.15

# --- Players ---------------------------------------------------------------

@export_group("Players")

## Whether a player may go solo (B): nobody sees them and nothing of theirs collides.
@export var allow_solo: bool = true

## Whether a solo player is hidden from everybody else as well as everybody from them.
## On by default: a truck others can see and drive through is a ghost, which is worse
## than a truck that is not there.
@export var solo_hidden_from_others: bool = true

## Whether trucks collide with each other at all, for players who are not solo.
@export var trucks_collide: bool = true

## Stand-in drivers, so a server is not an empty mountain. People replace them.
@export_range(0, 16, 1) var bots: int = 0

@export_group("Progress")

## Whether a server counts drivers' numbers and achievements at all.
@export var keep_progress: bool = true

## Whether they are reported to TMC's backbone (when the server has one).
@export var report_progress: bool = true

## Where achievement progress is kept between sessions. Empty keeps it in memory.
@export var progress_directory: String = "user://delivery_achievements"

@export_group("World")

## Gravity, written onto the world's own physics space.
@export_range(1.0, 30.0, 0.1) var gravity: float = 9.8

## The directory route documents are read from.
@export var route_directory: String = "routes"

## Which routes this server plays. Empty is every one it has.
@export var route_ids: PackedStringArray = PackedStringArray()

## A seed for everything drawn per trip. 0 takes one from the clock.
@export var seed_value: int = 0


func env_prefix() -> String:
	return "DD_"


func cli_prefix() -> String:
	return "--dd-"


func validate() -> DotResult:
	if gravity <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "gravity has to pull down.")

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"grip": "snow %.2f, rain %.2f" % [snow_grip, rain_grip],
		"wind": "%.1f m/s2" % wind_strength,
		"pay": "level +%.0f%%, chaos +%.0f%%/unit, clean +%.0f%%" % [
			level_pay_step * 100.0, chaos_pay * 100.0, clean_run_bonus * 100.0],
		"falls": "cargo -%.0f%%, back in %.1f s" % [fall_cargo_loss * 100.0, respawn_seconds],
		"boulders": ("%.0f%% each" % (boulder_chance * 100.0)) if boulders_enabled else "off",
		"solo": ("allowed" if allow_solo else "off"),
		"routes": "all" if route_ids.is_empty() else ",".join(route_ids),
	}


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("dangerous delivery configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])
	return lines
