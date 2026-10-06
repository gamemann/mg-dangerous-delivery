extends Node

## What a driver has done, as dot-stats numbers, and what they have earned, as achievements over
## those numbers — reported to TMC's backbone when the server has one, like every game here.
##
## [b]It listens and nothing calls it.[/b] The world's own signals (`delivered`, `fell`,
## `boulder_dropped`'s count on the trip) are the whole input, so a number cannot drift from
## what happened. Server only: a client counting its own deliveries is a client awarding itself.
##
## [b]Filed under the same key as the money[/b] (`uid:…`), so a driver's numbers and their bank
## are one person across reconnects. A stand-in is never counted.

const DdGame := preload("dd_game.gd")
const DdTrip := preload("dd_trip.gd")

const CHANNEL := "delivery.progress"

const DELIVERIES := &"dd.deliveries"
const CLEAN_DELIVERIES := &"dd.clean_deliveries"
const DISTANCE := &"dd.distance"
const EARNED := &"dd.earned"
const BEST_PAY := &"dd.best_pay"
const BEST_LEVEL := &"dd.best_level"
const FALLS := &"dd.falls"
const SNOW_DELIVERIES := &"dd.snow_deliveries"

signal earned(key: StringName, title: String, points: int)

var game: DdGame = null
var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null


static func schema() -> DotStatsSchema:
	var out := DotStatsSchema.new()
	_add(out, DELIVERIES, DotStatsDef.Kind.COUNTER, "Deliveries", "deliveries")
	_add(out, CLEAN_DELIVERIES, DotStatsDef.Kind.COUNTER, "Deliveries without a fall", "deliveries")
	_add(out, DISTANCE, DotStatsDef.Kind.COUNTER, "Distance hauled", "km")
	_add(out, EARNED, DotStatsDef.Kind.COUNTER, "Money earned", "dollars")
	_add(out, BEST_PAY, DotStatsDef.Kind.BEST, "Best single delivery", "dollars")
	_add(out, BEST_LEVEL, DotStatsDef.Kind.BEST, "Hardest route delivered", "level")
	_add(out, FALLS, DotStatsDef.Kind.COUNTER, "Times over the edge", "falls")
	_add(out, SNOW_DELIVERIES, DotStatsDef.Kind.COUNTER, "Deliveries through snow", "deliveries")
	return out


static func _add(out: DotStatsSchema, id: StringName, kind: DotStatsDef.Kind, display: String, unit: String) -> void:
	var def := DotStatsDef.make(id, kind, display)
	def.unit = unit
	def.publish = true
	out.stats.append(def)


static func catalogue() -> DotAchievementCatalogue:
	var made: Array[DotAchievement] = []
	made.append(_rule(&"dd.first_load", "First Load", DELIVERIES, 1.0, 10, "Deliver a load.", &"dd.loads", 1))
	made.append(_rule(&"dd.regular", "Regular", DELIVERIES, 25.0, 30, "Deliver twenty-five loads.", &"dd.loads", 2))
	made.append(_rule(&"dd.not_a_scratch", "Not a Scratch", CLEAN_DELIVERIES, 1.0, 15, "Deliver without going over the edge or skipping."))
	made.append(_rule(&"dd.snowplough", "Snowplough", SNOW_DELIVERIES, 5.0, 25, "Deliver five loads through snow."))
	made.append(_rule(&"dd.long_haul", "Long Haul", DISTANCE, 50.0, 30, "Haul fifty kilometres."))
	made.append(_rule(&"dd.payday", "Payday", BEST_PAY, 3000.0, 25, "Earn $3,000 for one delivery.", &"", 0, DotAchievementRule.Merge.HIGHEST))
	made.append(_rule(&"dd.summit", "Summit", BEST_LEVEL, 5.0, 40, "Deliver a level 5 route.", &"", 0, DotAchievementRule.Merge.HIGHEST))
	# Secret, and earned by the thing the game is about.
	var gravity := _rule(&"dd.gravity_wins", "Gravity Wins", FALLS, 50.0, 10, "Go over the edge fifty times.")
	gravity.secret = true
	made.append(gravity)
	var out := DotAchievementCatalogue.new()
	out.achievements = made
	return out


static func _rule(id: StringName, title: String, stat: StringName, target: float, points: int, description: String,
		series: StringName = &"", tier: int = 0, merge: int = DotAchievementRule.Merge.SUM) -> DotAchievement:
	var out := DotAchievement.make(id, title, [
		DotAchievementRule.make(stat, target, DotAchievementRule.Op.AT_LEAST, merge),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


## [param directory] keeps achievement progress on disk ("" keeps it in memory); [param report]
## sends both to the backbone.
func setup(world: DdGame, directory: String, report: bool) -> DotResult:
	game = world
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = schema()
	stats.report_to_backbone = report
	stats.define_on_start = report
	add_child(stats)
	var counted := stats.start()

	if not counted.ok:
		return counted.wrap("delivery stats")

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.report_to_backbone = report
	achievements.register_as = &""

	if directory != "":
		var file_store := DotAchievementStoreFile.new()
		file_store.directory = directory
		achievements.store = file_store
	else:
		achievements.store = DotAchievementStoreMemory.new()

	add_child(achievements)
	var awarded := achievements.start()

	if not awarded.ok:
		return awarded.wrap("delivery achievements")

	achievements.unlocked.connect(func(player_id: String, achievement: DotAchievement) -> void:
		earned.emit(StringName(player_id), achievement.display_name, achievement.points))

	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)
	var linked := link.start()

	if not linked.ok:
		return linked.wrap("the stats-to-achievements link")

	game.delivered.connect(_on_delivered)
	game.fell.connect(func(key: StringName, why: String) -> void:
		if why != "respawn":
			record(key, FALLS))
	game.driver_left.connect(leave)
	return DotResult.success(self)


func _on_delivered(key: StringName, route_id: StringName, pay: int) -> void:
	var driver: DdGame.Driver = game.drivers.get(key, null)

	if driver == null or driver.trip == null:
		return

	var trip: DdTrip = driver.trip
	record(key, DELIVERIES)
	record(key, EARNED, float(pay))
	record(key, BEST_PAY, float(pay))
	record(key, BEST_LEVEL, float(trip.level))
	record(key, DISTANCE, game.routes[route_id].length() / 1000.0)

	if trip.falls == 0 and trip.skips == 0:
		record(key, CLEAN_DELIVERIES)

	for met: String in trip.met:
		if met.ends_with("|2"):
			record(key, SNOW_DELIVERIES)
			break


func record(key: StringName, stat: StringName, value: float = 1.0) -> void:
	var driver: DdGame.Driver = game.drivers.get(key, null) if game != null else null

	if stats == null or driver == null or driver.is_bot:
		return

	if not stats.has_player(key):
		stats.begin(key, driver.name)
		_begin(key)

	var filed := stats.record(key, stat, value)

	if not filed.ok:
		DotLog.warn(CHANNEL, "a reading was refused", {"player": String(key), "stat": String(stat), "why": filed.error.message})


func _begin(key: StringName) -> void:
	var began: DotResult = await achievements.begin(String(key))

	if not began.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be loaded", {"player": String(key), "why": began.error.message})


func leave(key: StringName) -> void:
	if stats == null or not stats.has_player(key):
		return

	var _values := stats.end(key)
	link.forget(String(key))
	var ended: DotResult = await achievements.end(String(key))

	if not ended.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be saved", {"player": String(key), "why": ended.error.message})


func session_values(key: StringName) -> DotStatsValues:
	return stats.session_values(key) if stats != null else DotStatsValues.new()
