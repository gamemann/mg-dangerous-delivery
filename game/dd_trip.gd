extends RefCounted

## One player's haul: which route, which truck, how far, how much cargo is left, and what it
## went through on the way.
##
## [b]What a trip pays is measured, not drawn.[/b] The chaos a trip is paid for is the weather
## it actually drove through and the rock that actually came down near it — counted per zone,
## once each, as the truck enters them — because the brief is "the more chaos, the more money"
## and a bonus for a blizzard the player never met is a bonus for nothing.

const DdWeather := preload("dd_weather.gd")

enum State { HOLD, DRIVING, FALLEN, DELIVERED }

var route_id: StringName = &""
var truck_id: StringName = &""
var level: int = 1
var base_pay: float = 300.0
var truck_pay: float = 1.0
var stages: int = 1

var state: State = State.HOLD

## Seconds left in [constant State.HOLD], and in [constant State.FALLEN] before the truck is
## put back.
var wait: float = 0.0

## Furthest checkpoint reached: where a fall puts the truck back.
var stage: int = 0

## Distance along the road now, and the furthest it has been.
var distance: float = 0.0
var furthest: float = 0.0

## The nearest road sample last tick, for [method DdRoute.nearest_index]'s hint.
var hint: int = 0

## What is left of the load, 1 to 0.
var cargo: float = 1.0

var falls: int = 0
var skips: int = 0
var boulders: int = 0

## Seconds on its side or back.
var flipped_for: float = 0.0

## Seconds since it set off, held time excluded.
var seconds: float = 0.0

## "zone|sky" and "zone|wind" already counted, so a zone pays its weather once per trip.
var met: Dictionary = {}

## The chaos units counted so far (see [member met] and [member boulders]).
var chaos_units: float = 0.0

## What it paid, once delivered.
var paid: int = 0

## Speed last tick, for the knock test.
var last_velocity: Vector3 = Vector3.ZERO


func reset_to_start(hold_seconds: float) -> void:
	state = State.HOLD
	wait = hold_seconds
	stage = 0
	distance = 0.0
	furthest = 0.0
	hint = 0
	cargo = 1.0
	falls = 0
	skips = 0
	boulders = 0
	flipped_for = 0.0
	seconds = 0.0
	met = {}
	chaos_units = 0.0
	paid = 0
	last_velocity = Vector3.ZERO


## Counts the weather in [param zone] once. Returns whether it was new.
func meet(zone: String, weather: Dictionary, snow_chaos: float, rain_chaos: float, wind_chaos: float) -> bool:
	var fresh := false
	var sky := int(weather.get("sky", DdWeather.CLEAR))

	if sky != DdWeather.CLEAR:
		var key := "%s|%d" % [zone, sky]

		if not met.has(key):
			met[key] = true
			chaos_units += snow_chaos if sky == DdWeather.SNOW else rain_chaos
			fresh = true

	if bool(weather.get("wind", false)):
		var key := "%s|wind" % zone

		if not met.has(key):
			met[key] = true
			chaos_units += wind_chaos
			fresh = true

	return fresh


## What delivering now pays, from the configuration's numbers. Pure arithmetic over the trip,
## so the HUD can show what is on offer before it is earned.
func pay_now(config: Object) -> int:
	var amount := base_pay
	amount *= 1.0 + float(config.get("level_pay_step")) * float(level - 1)
	amount *= truck_pay
	amount *= 1.0 + float(config.get("chaos_pay")) * chaos_units

	if bool(config.get("cargo_condition_pays")):
		amount *= maxf(cargo, float(config.get("minimum_pay_fraction")))

	if falls == 0 and skips == 0:
		amount *= 1.0 + float(config.get("clean_run_bonus"))

	amount *= maxf(1.0 - float(config.get("skip_cost_fraction")) * float(skips), 0.0)
	return int(round(amount))


func is_driving() -> bool:
	return state == State.DRIVING


func state_name() -> String:
	return ["hold", "driving", "fallen", "delivered"][state]


func describe() -> Dictionary:
	return {
		"route": String(route_id), "truck": String(truck_id), "state": state_name(),
		"stage": "%d/%d" % [stage, stages], "at": "%.0f m" % distance, "cargo": "%.0f%%" % (cargo * 100.0),
		"falls": falls, "skips": skips, "chaos": "%.2f" % chaos_units, "seconds": "%.0f" % seconds,
	}
