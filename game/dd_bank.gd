extends Node

## What a player has: their money, their trucks, their upgrades, how far they have got.
##
## [b]The server's, always.[/b] A client is shown its account and asks to spend it; the
## server checks the price against the balance it holds and says yes or no. An account a
## client kept would be an account a client edits.
##
## [b]Where it is kept is the owner's choice, and the brief named three databases.[/b] The
## store is duck-typed: [code]load_account(key) -> Dictionary[/code] and
## [code]save_account(key, account) -> DotResult[/code]. Two ship here:
##
## - [JsonStore], one file (`user://delivery_accounts.json` by default). A single box, nothing
##   to install, and the default.
## - [SqlStore], over any driver with dot-moderation's shape — [code]execute(sql, params)[/code],
##   [code]query(sql, params)[/code], [code]dialect()[/code] — so the SQLite, PostgreSQL and
##   MySQL drivers an owner already configured for bans keep the money too. One table, with
##   money and deliveries as columns a web panel can sort by and the rest as JSON.
##
## [b]Saved on every change that matters (a delivery, a purchase), not on a timer.[/b] Money is
## the one thing a player will notice going missing after a crash.

const CHANNEL := "delivery.bank"

## A player's account changed: the module sends it to them, the HUD redraws.
signal account_changed(key: StringName)

## Money went in or out: [param amount] signed, [param why] a word for the log and the stats.
signal money_moved(key: StringName, amount: int, why: String)

## key -> account Dictionary. See [method blank].
var accounts: Dictionary = {}

## The store. Null keeps accounts in memory only, which is what a test wants.
var store: Object = null

## Money a new account starts with (DdConfig.starting_money).
var starting_money: int = 0

## The truck a new account owns (DdTrucks.starter()).
var starter_truck: StringName = &"box_truck"


## A new player's account.
func blank(name_text: String) -> Dictionary:
	return {
		"name": name_text, "money": starting_money,
		"trucks": [String(starter_truck)], "truck": String(starter_truck),
		"upgrades": {}, "delivered": [], "deliveries": 0, "earned": 0,
		"distance": 0.0, "falls": 0,
	}


## The account for [param key], loaded from the store the first time it is asked for.
func account(key: StringName, name_text: String = "") -> Dictionary:
	if accounts.has(key):
		return accounts[key]

	var loaded: Dictionary = {}

	if store != null:
		var got: Variant = store.call("load_account", String(key))

		if got is Dictionary:
			loaded = got

	var acct := blank(name_text if name_text != "" else String(key))

	# Merged over a blank one, so an account saved before a field existed gains it.
	acct.merge(loaded, true)

	if name_text != "":
		acct["name"] = name_text

	accounts[key] = acct
	return acct


func money(key: StringName) -> int:
	return int(account(key).get("money", 0))


func owns(key: StringName, truck_id: StringName) -> bool:
	return (account(key)["trucks"] as Array).has(String(truck_id))


func upgrade_level(key: StringName, truck_id: StringName, kind: String) -> int:
	var per_truck: Dictionary = (account(key)["upgrades"] as Dictionary).get(String(truck_id), {})
	return int(per_truck.get(kind, 0))


func upgrades_of(key: StringName, truck_id: StringName) -> Dictionary:
	return (account(key)["upgrades"] as Dictionary).get(String(truck_id), {})


## Pays [param amount] in. Negative is allowed for a penalty; the balance never goes below 0.
func credit(key: StringName, amount: int, why: String) -> int:
	var acct := account(key)
	var before := int(acct["money"])
	acct["money"] = maxi(before + amount, 0)

	if amount > 0:
		acct["earned"] = int(acct.get("earned", 0)) + amount

	money_moved.emit(key, int(acct["money"]) - before, why)
	_changed(key)
	return int(acct["money"])


## Spends [param price] if the balance covers it. The refusal is the reason, for the player.
func spend(key: StringName, price: int, why: String) -> DotResult:
	var acct := account(key)

	if price < 0:
		return DotResult.fail(DotError.CODE_INVALID, "A price cannot be negative.")

	if int(acct["money"]) < price:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That costs %d and you have %d." % [price, int(acct["money"])])

	acct["money"] = int(acct["money"]) - price
	money_moved.emit(key, -price, why)
	_changed(key)
	return DotResult.success(int(acct["money"]))


func buy_truck(key: StringName, truck_id: StringName, price: int) -> DotResult:
	if owns(key, truck_id):
		return DotResult.fail(DotError.CODE_STATE, "You already own that truck.")

	var paid := spend(key, price, "truck:%s" % truck_id)

	if not paid.ok:
		return paid

	(account(key)["trucks"] as Array).append(String(truck_id))
	account(key)["truck"] = String(truck_id)
	_changed(key)
	return DotResult.success(truck_id)


func select_truck(key: StringName, truck_id: StringName) -> DotResult:
	if not owns(key, truck_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "You do not own that truck.")

	account(key)["truck"] = String(truck_id)
	_changed(key)
	return DotResult.success(truck_id)


func buy_upgrade(key: StringName, truck_id: StringName, kind: String, price: int) -> DotResult:
	if not owns(key, truck_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "You do not own that truck.")

	if price < 0:
		return DotResult.fail(DotError.CODE_STATE, "That is as good as it gets.")

	var paid := spend(key, price, "upgrade:%s:%s" % [truck_id, kind])

	if not paid.ok:
		return paid

	var upgrades: Dictionary = account(key)["upgrades"]
	var per_truck: Dictionary = upgrades.get(String(truck_id), {})
	per_truck[kind] = int(per_truck.get(kind, 0)) + 1
	upgrades[String(truck_id)] = per_truck
	_changed(key)
	return DotResult.success(per_truck[kind])


## A trip delivered: the pay, and the route marked done.
func note_delivery(key: StringName, route_id: StringName, pay: int, distance: float, falls: int) -> void:
	var acct := account(key)
	var done: Array = acct["delivered"]

	if not done.has(String(route_id)):
		done.append(String(route_id))

	acct["deliveries"] = int(acct.get("deliveries", 0)) + 1
	acct["distance"] = float(acct.get("distance", 0.0)) + distance
	acct["falls"] = int(acct.get("falls", 0)) + falls
	credit(key, pay, "delivery:%s" % route_id)


func has_delivered(key: StringName, route_id: StringName) -> bool:
	return (account(key)["delivered"] as Array).has(String(route_id))


func _changed(key: StringName) -> void:
	if store != null:
		var saved: Variant = store.call("save_account", String(key), accounts[key])

		if saved is DotResult and not (saved as DotResult).ok:
			DotLog.error(CHANNEL, "an account could not be saved", {
				"key": String(key), "why": (saved as DotResult).error.message})

	account_changed.emit(key)


## What a client is sent about its own account. Everything except what it does not need.
func view_of(key: StringName) -> Dictionary:
	var acct := account(key)
	return {
		"money": int(acct["money"]), "trucks": acct["trucks"], "truck": acct["truck"],
		"upgrades": acct["upgrades"], "delivered": acct["delivered"],
		"deliveries": int(acct.get("deliveries", 0)),
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["accounts (%d)%s" % [accounts.size(), "" if store != null else ", in memory only"]])

	for key: StringName in accounts:
		var acct: Dictionary = accounts[key]
		lines.append("  %-20s %8d  %d deliveries  %s" % [acct["name"], int(acct["money"]), int(acct.get("deliveries", 0)), ",".join(acct["trucks"])])

	return lines


# --- Stores ------------------------------------------------------------------

## Every account in one JSON file.
class JsonStore:
	extends RefCounted

	var path: String = "user://delivery_accounts.json"
	var _all: Dictionary = {}
	var _read: bool = false

	func _init(p_path: String = "") -> void:
		if p_path != "":
			path = p_path

	func load_account(key: String) -> Dictionary:
		_read_file()
		return (_all.get(key, {}) as Dictionary).duplicate(true)

	func save_account(key: String, account: Dictionary) -> DotResult:
		_read_file()
		_all[key] = account.duplicate(true)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)

		if file == null:
			return DotResult.fail(DotError.CODE_IO, "Cannot write %s (%s)." % [path, error_string(FileAccess.get_open_error())])

		file.store_string(JSON.stringify(_all, "\t"))
		file.close()
		DotWeb.sync_filesystem()
		return DotResult.success(true)

	func _read_file() -> void:
		if _read:
			return

		_read = true

		if not FileAccess.file_exists(path):
			return

		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))

		if parsed is Dictionary:
			_all = parsed


## One table over a dot-moderation-shaped SQL driver.
class SqlStore:
	extends RefCounted

	const SQLITE := 0
	const POSTGRES := 1
	const MYSQL := 2

	var driver: Object = null
	var table: String = "delivery_accounts"
	var _ready: bool = false

	func _init(p_driver: Object = null, p_table: String = "") -> void:
		driver = p_driver

		if p_table != "":
			table = p_table

	func dialect() -> int:
		return int(driver.call("dialect")) if driver != null and driver.has_method("dialect") else SQLITE

	## The table, created once. Money and deliveries are columns so a panel can rank by them;
	## everything else is one JSON column, because the shape of an account will grow.
	func create_sql() -> String:
		var text := "TEXT"
		var big := "BIGINT"
		return ("CREATE TABLE IF NOT EXISTS %s (player_key VARCHAR(128) PRIMARY KEY, display_name VARCHAR(128), "
			+ "money %s NOT NULL DEFAULT 0, deliveries INTEGER NOT NULL DEFAULT 0, data %s, updated_at %s)") % [table, big, text, big]

	func upsert_sql() -> String:
		var cols := "(player_key, display_name, money, deliveries, data, updated_at)"

		match dialect():
			POSTGRES:
				return ("INSERT INTO %s %s VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (player_key) DO UPDATE SET "
					+ "display_name = EXCLUDED.display_name, money = EXCLUDED.money, deliveries = EXCLUDED.deliveries, "
					+ "data = EXCLUDED.data, updated_at = EXCLUDED.updated_at") % [table, cols]
			MYSQL:
				return ("INSERT INTO %s %s VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE "
					+ "display_name = VALUES(display_name), money = VALUES(money), deliveries = VALUES(deliveries), "
					+ "data = VALUES(data), updated_at = VALUES(updated_at)") % [table, cols]

		return ("INSERT INTO %s %s VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(player_key) DO UPDATE SET "
			+ "display_name = excluded.display_name, money = excluded.money, deliveries = excluded.deliveries, "
			+ "data = excluded.data, updated_at = excluded.updated_at") % [table, cols]

	func select_sql() -> String:
		var mark := "$1" if dialect() == POSTGRES else "?"
		return "SELECT player_key, display_name, money, deliveries, data FROM %s WHERE player_key = %s" % [table, mark]

	func _ensure() -> DotResult:
		if _ready:
			return DotResult.success(true)

		if driver == null:
			return DotResult.fail(DotError.CODE_STATE, "No SQL driver.")

		if driver.has_method("is_open") and not bool(driver.call("is_open")) and driver.has_method("open"):
			var opened: Variant = driver.call("open")

			if opened is DotResult and not (opened as DotResult).ok:
				return opened

		var made: Variant = driver.call("execute", create_sql(), [])

		if made is DotResult and not (made as DotResult).ok:
			return made

		_ready = true
		return DotResult.success(true)

	func load_account(key: String) -> Dictionary:
		if not _ensure().ok:
			return {}

		var got: Variant = driver.call("query", select_sql(), [key])

		if not (got is DotResult) or not (got as DotResult).ok:
			return {}

		var rows: Variant = (got as DotResult).value

		if not (rows is Array) or (rows as Array).is_empty():
			return {}

		var row: Variant = (rows as Array)[0]
		var data_text := ""
		var money := 0
		var deliveries := 0
		var display := ""

		# A row is a Dictionary by column or an Array in column order: dot-moderation's
		# drivers return either, and the store reads both rather than trusting one.
		if row is Dictionary:
			data_text = str((row as Dictionary).get("data", ""))
			money = int((row as Dictionary).get("money", 0))
			deliveries = int((row as Dictionary).get("deliveries", 0))
			display = str((row as Dictionary).get("display_name", ""))
		elif row is Array and (row as Array).size() >= 5:
			display = str(row[1])
			money = int(row[2])
			deliveries = int(row[3])
			data_text = str(row[4])

		var data: Variant = JSON.parse_string(data_text) if data_text != "" else {}
		var out: Dictionary = data if data is Dictionary else {}
		# The columns win over the JSON: they are what an operator edits by hand.
		out["money"] = money
		out["deliveries"] = deliveries

		if display != "":
			out["name"] = display

		return out

	func save_account(key: String, account: Dictionary) -> DotResult:
		var ready := _ensure()

		if not ready.ok:
			return ready

		var params := [
			key, str(account.get("name", key)), int(account.get("money", 0)),
			int(account.get("deliveries", 0)), JSON.stringify(account), int(Time.get_unix_time_from_system()),
		]
		var done: Variant = driver.call("execute", upsert_sql(), params)
		return done if done is DotResult else DotResult.success(true)
