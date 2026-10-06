extends RefCounted

## Every truck a player can buy, and every upgrade, as data.
##
## [b]A harder truck pays more, and that is the whole economy in one number.[/b] Each truck
## has a `pay` multiplier; the ones that are slower to stop, quicker to slide or longer round
## a hairpin carry more of it. A server owner who disagrees overrides any field from
## `user://cfg/delivery_trucks.json` (the same keys, by truck id), or adds a truck.
##
## [b]Handling is in dot-vehicle's own units[/b] (newtons, metres per second, degrees), and
## every field is applied to a [DotVehicleTunables], so the chassis that drives a truck is
## the one every vehicle in the family is driven by.

## The trucks, in the order the garage shows them.
const DEFAULTS := [
	{
		"id": "box_truck", "name": "Box Truck", "model": "delivery.glb", "scale": 1.7,
		"blurb": "Short, forgiving and slow. Everybody starts in one.",
		"price": 0, "pay": 1.0, "mass": 4500.0, "engine_force": 20800.0, "top_speed": 19.0,
		"brake_force": 9100.0, "steering_limit_deg": 34.0, "steering_speed_falloff": 0.4,
		"friction_slip": 3.2, "rear_grip_fraction": 0.95, "centre_of_mass_drop": 0.7,
	},
	{
		"id": "flatbed", "name": "Flatbed", "model": "truck-flat.glb", "scale": 1.8,
		"blurb": "Quicker, lighter at the back, and the load is out in the wind.",
		"price": 1500, "pay": 1.3, "mass": 5200.0, "engine_force": 27200.0, "top_speed": 23.0,
		"brake_force": 9100.0, "steering_limit_deg": 30.0, "steering_speed_falloff": 0.35,
		"friction_slip": 2.9, "rear_grip_fraction": 0.85, "centre_of_mass_drop": 0.55,
		"wind_scale": 1.4,
	},
	{
		"id": "hauler", "name": "Hauler", "model": "truck.glb", "scale": 1.9,
		"blurb": "Heavy and long. It stops late and it does not like hairpins.",
		"price": 4000, "pay": 1.6, "mass": 8000.0, "engine_force": 35200.0, "top_speed": 21.0,
		"brake_force": 10500.0, "steering_limit_deg": 28.0, "steering_speed_falloff": 0.3,
		"friction_slip": 2.8, "rear_grip_fraction": 0.9, "centre_of_mass_drop": 0.5,
	},
	{
		"id": "bulk", "name": "Bulk Carrier", "model": "garbage-truck.glb", "scale": 2.0,
		"blurb": "The most it can carry, the least it can steer. Pays like it.",
		"price": 9000, "pay": 2.1, "mass": 11000.0, "engine_force": 43200.0, "top_speed": 18.0,
		"brake_force": 11200.0, "steering_limit_deg": 26.0, "steering_speed_falloff": 0.28,
		"friction_slip": 2.6, "rear_grip_fraction": 0.85, "centre_of_mass_drop": 0.45,
		"wind_scale": 1.2,
	},
]

## What an upgrade level adds, per kind, and what each level costs as a fraction of the
## truck's price (with a floor, so the free truck's upgrades are not free).
const UPGRADES := {
	"engine": {"name": "Engine", "step": 0.12, "levels": 3},
	"brakes": {"name": "Brakes", "step": 0.15, "levels": 3},
	"tyres": {"name": "Tyres", "step": 0.08, "levels": 3},
}

const UPGRADE_COST := [0.25, 0.5, 0.9]
const UPGRADE_COST_FLOOR := [300, 700, 1400]

## id -> definition (Dictionary).
var trucks: Dictionary = {}

## Ids in garage order.
var order: Array[StringName] = []


func _init() -> void:
	reset()


func reset() -> void:
	trucks.clear()
	order.clear()

	for def: Dictionary in DEFAULTS:
		trucks[StringName(def["id"])] = def.duplicate(true)
		order.append(StringName(def["id"]))


## Applies an owner's overrides: [code]{"hauler": {"price": 5000}, "my_truck": {...}}[/code].
## A new id must carry everything a truck needs; it is checked like the built-in ones.
func apply_overrides(data: Dictionary) -> DotResult:
	for key: Variant in data:
		var id := StringName(str(key))
		var fields: Variant = data[key]

		if not (fields is Dictionary):
			return DotResult.fail(DotError.CODE_INVALID, "truck '%s' is not an object." % id)

		var def: Dictionary = trucks.get(id, (DEFAULTS[0] as Dictionary).duplicate(true))
		def.merge(fields, true)
		def["id"] = String(id)

		if not trucks.has(id):
			order.append(id)

		trucks[id] = def

	return DotResult.success(trucks.size())


func load_overrides(path: String) -> DotResult:
	if path == "" or not FileAccess.file_exists(path):
		return DotResult.success(0)

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))

	if not (parsed is Dictionary):
		return DotResult.fail(DotError.CODE_INVALID, "%s is not a JSON object of truck id to fields." % path)

	return apply_overrides(parsed)


func get_truck(id: StringName) -> Dictionary:
	return trucks.get(id, {})


func starter() -> StringName:
	for id in order:
		if int(trucks[id].get("price", 0)) <= 0:
			return id

	return order[0] if not order.is_empty() else &""


## What the next level of [param kind] costs on [param truck_id], or -1 when it is maxed.
func upgrade_cost(truck_id: StringName, kind: String, current_level: int) -> int:
	var spec: Dictionary = UPGRADES.get(kind, {})

	if spec.is_empty() or current_level >= int(spec["levels"]):
		return -1

	var price := int(get_truck(truck_id).get("price", 0))
	return maxi(int(price * float(UPGRADE_COST[current_level])), int(UPGRADE_COST_FLOOR[current_level]))


## The tunables a truck drives with, its upgrades applied.
func tunables_for(truck_id: StringName, levels: Dictionary = {}) -> DotVehicleTunables:
	var def := get_truck(truck_id)
	var t := DotVehicleTunables.new()
	var engine := 1.0 + float(UPGRADES["engine"]["step"]) * int(levels.get("engine", 0))
	var brakes := 1.0 + float(UPGRADES["brakes"]["step"]) * int(levels.get("brakes", 0))
	var tyres := 1.0 + float(UPGRADES["tyres"]["step"]) * int(levels.get("tyres", 0))

	t.mass = float(def.get("mass", 4500.0))
	t.engine_force = float(def.get("engine_force", 12000.0)) * engine
	t.top_speed = float(def.get("top_speed", 20.0)) * (1.0 + (engine - 1.0) * 0.4)
	t.brake_force = float(def.get("brake_force", 20000.0)) * brakes
	t.handbrake_force = t.brake_force * 0.5
	t.steering_limit_deg = float(def.get("steering_limit_deg", 32.0))
	t.steering_speed_falloff = float(def.get("steering_speed_falloff", 0.35))
	t.friction_slip = float(def.get("friction_slip", 3.0)) * tyres
	t.rear_grip_fraction = float(def.get("rear_grip_fraction", 0.9))
	t.centre_of_mass_drop = float(def.get("centre_of_mass_drop", 0.6))
	t.suspension_travel = 0.3
	t.suspension_stiffness = 60.0
	return t


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["trucks (%d)" % order.size()])

	for id in order:
		var def: Dictionary = trucks[id]
		lines.append("  %-12s %-14s %6d  pay x%.1f  %5.0f kg  %4.1f m/s" % [
			id, def.get("name", id), int(def.get("price", 0)), float(def.get("pay", 1.0)),
			float(def.get("mass", 0.0)), float(def.get("top_speed", 0.0))])

	return lines
