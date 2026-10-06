extends RefCounted

## What the sky is doing over each zone, as a pure function of the seed, the zone and the
## tick.
##
## [b]The world's weather, not a trip's.[/b] Several trucks share one mountain, so snow on the
## pass is snow for everybody on it — a per-trip draw would put one driver in a blizzard and
## the driver beside them in sunshine on the same bend. What a trip earns for bad weather is
## measured from the weather it actually drove through ([DdTrip]), not drawn for it.
##
## [b]A function of the tick, like mg-wipeout's obstacles[/b], so nothing about it is ever sent
## after the seed: a client paints a zone white on the same tick the server makes it slippery.
## The weather holds for [constant PERIOD_SECONDS] and is drawn again, per zone, from a hash —
## not from a random stream, whose answer depends on how many times somebody asked it.

## How long one draw of a zone's weather lasts.
const PERIOD_SECONDS := 150.0

const CLEAR := 0
const RAIN := 1
const SNOW := 2


## The weather over [param zone_id] at [param tick]: [code]{"sky": CLEAR/RAIN/SNOW, "wind": bool}[/code].
##
## [param zone] is the document's zone ({snow, rain, wind} chances); [param frequency]
## multiplies every chance (DdConfig.weather_frequency). Snow is drawn before rain, so a zone
## that may do both does the colder one when both come up.
static func at(seed_value: int, zone_id: String, zone: Dictionary, tick: int, tick_rate: int, frequency: float = 1.0) -> Dictionary:
	if zone.is_empty():
		return {"sky": CLEAR, "wind": false}

	var period := int(floor(float(tick) / (PERIOD_SECONDS * float(maxi(tick_rate, 1)))))
	var sky := CLEAR

	if _roll(seed_value, zone_id, period, 1) < float(zone.get("snow", 0.0)) * frequency:
		sky = SNOW
	elif _roll(seed_value, zone_id, period, 2) < float(zone.get("rain", 0.0)) * frequency:
		sky = RAIN

	var windy := _roll(seed_value, zone_id, period, 3) < float(zone.get("wind", 0.0)) * frequency
	return {"sky": sky, "wind": windy}


## The wind's side force at [param tick], from -1 to 1: a slow swell with gusts on it. Which
## way it blows is the zone's, from the hash, so a pass blows the same way for everybody.
static func gust(seed_value: int, zone_id: String, tick: int, tick_rate: int) -> float:
	var t := float(tick) / float(maxi(tick_rate, 1))
	var direction := 1.0 if _roll(seed_value, zone_id, 0, 4) < 0.5 else -1.0
	var swell := 0.55 + 0.45 * sin(t * 0.35 + _roll(seed_value, zone_id, 0, 5) * TAU)
	var gusts := maxf(sin(t * 1.7) * sin(t * 0.61 + 1.3), 0.0)
	return direction * clampf(swell * 0.6 + gusts * 0.8, 0.0, 1.0)


## A number in [0, 1) from the inputs alone. The same on every machine and every run.
static func _roll(seed_value: int, zone_id: String, period: int, salt: int) -> float:
	return unit("%d|%s|%d|%d" % [seed_value, zone_id, period, salt])


## A number in [0, 1) from [param text], well mixed.
##
## [b]Not [code]hash()[/code].[/b] Godot's string hash is djb2, and two strings that differ in
## their last character differ only in the hash's low bits: period 0 to period 5 of one zone
## rolled 0.2816 to 0.2819, so a zone that should have been snowy half the time was snowy every
## time or never. MD5 is overkill as a hash and exactly right as a mixer, and it is the same
## on every platform.
static func unit(text: String) -> float:
	return float(text.md5_text().substr(0, 8).hex_to_int()) / 4294967296.0


## Grip on a road under [param weather], from the configuration's multipliers.
static func grip(weather: Dictionary, snow_grip: float, rain_grip: float) -> float:
	match int(weather.get("sky", CLEAR)):
		SNOW:
			return snow_grip
		RAIN:
			return rain_grip
	return 1.0


static func sky_name(sky: int) -> String:
	return ["clear", "rain", "snow"][clampi(sky, 0, 2)]
