extends Node

## A player's own settings: how wide the view is, how loud the game is.
##
## [b]mg-buses-from-hell's `BfhSettings`, cut down to what mg-dangerous-delivery has[/b] (2026-10-08). That
## file binds dot-audio's mixer; this game plays its sounds through its own players on the
## engine's Master bus, so the volume is that bus's and there is one of it, because there is
## nothing to split a voice or an effects slider from. The rest of the reasoning is that
## file's and still true: `apply_all()` after load (a value read from disk has not CHANGED,
## and a game that only listens for changes ignores every saved setting), `sensitivity` is
## ACCOUNT under the family's `tmc_account` at its 0.022 degrees per unit, and
## `field_of_view` is SERVER_CLAMPED, a bound a server may set and never read.
##
## [b]No sensitivity, though every other game has one.[/b] A player here is their truck: the
## mouse turns nothing, the camera follows the cab, and a setting nobody reads is a slider
## that does nothing — the thing `BfhSettings`' own note says every setting must not be.

const CHANNEL := "dd.settings"

const SCHEMA_VERSION := 1

const SETTINGS_DIR := "user://delivery_settings"

const APP_NAMESPACE := &"dangerous_delivery"
const SHARED_NAMESPACE := &"tmc_account"

## The field of view the camera had before this existed, and still the default.
const DEFAULT_FOV := 70

var settings: DotSettingsManager = null

## The menu the screen lives in. Null when built without a screen.
var stack: DotScreenStack = null
var screen: DotSettingsScreen = null

var _layer: CanvasLayer = null
var _camera: Camera3D = null


static func schema() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION

	s.add(DotSettingsDef.integer(&"field_of_view", DEFAULT_FOV, 60, 120, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))

	s.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
	return s


## Loads the document and builds the screen. [param store] replaces the file store, which
## is what a suite does; [param with_screen] false builds the document alone.
func setup(store: DotSettingsStore = null, with_screen: bool = true) -> DotResult:
	settings = DotSettingsManager.new()
	settings.name = "Manager"
	settings.schema = schema()
	settings.local_store = store if store != null else DotSettingsStoreFile.new(SETTINGS_DIR)
	settings.app_namespace = APP_NAMESPACE
	settings.shared_namespace = SHARED_NAMESPACE
	settings.register_as_service = false
	add_child(settings)

	var loaded := settings.setup()
	if not loaded.ok:
		return loaded.wrap("the player's settings")

	settings.changed.connect(_on_changed)

	if with_screen:
		var built := _build_screen()
		if not built.ok:
			DotLog.warn(CHANNEL, "no settings screen", {"why": built.error.message})

	apply_all()
	return DotResult.success(self)


func _build_screen() -> DotResult:
	_layer = CanvasLayer.new()
	_layer.name = "MenuLayer"
	# Over the HUD and the chat box: a menu under the chat has a line of text across Apply.
	_layer.layer = 110
	add_child(_layer)

	stack = DotScreenStack.new()
	stack.name = "Menus"
	stack.register_service = false
	# The client owns the pointer; a browser only captures on a click.
	stack.manage_mouse = false
	var config := DotUiConfig.new()
	# Never paused: the server does not stop for one player's volume.
	config.allow_pause = false
	stack.config = config
	_layer.add_child(stack)

	var stacked := stack.setup()
	if not stacked.ok:
		return stacked

	screen = DotSettingsScreen.new()
	screen.name = "Settings"
	screen.title_text = "Settings"
	screen.half_size = Vector2(280.0, 140.0)
	var built := screen.build(settings)
	if not built.ok:
		screen.free()
		screen = null
		return built

	return stack.register(screen)


## Pushes every current value at whatever reads it. See the class note.
func apply_all() -> void:
	if settings == null:
		return

	for key in settings.schema.keys():
		_on_changed(key, settings.get_value(key), &"applied")


func bind_camera(camera: Camera3D) -> void:
	_camera = camera
	_apply_fov()


func _on_changed(key: StringName, _value: Variant, _why: StringName) -> void:
	match key:
		&"field_of_view":
			_apply_fov()
		&"master_volume":
			_apply_volume()


func _apply_fov() -> void:
	if _camera != null and settings != null:
		_camera.fov = float(settings.get_int(&"field_of_view", DEFAULT_FOV))


## The engine's Master bus, which every sound in this game goes through. A silent setting
## is a bus muted rather than at minus infinity decibels, which some drivers click on.
func _apply_volume() -> void:
	if settings == null:
		return

	var bus := AudioServer.get_bus_index(&"Master")
	if bus < 0:
		return

	var level := clampf(settings.get_float(&"master_volume", 0.8), 0.0, 1.0)
	AudioServer.set_bus_mute(bus, level <= 0.0001)
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(level, 0.0001)))


func is_open() -> bool:
	return stack != null and stack.any_open()


func open() -> void:
	if stack != null and screen != null and not stack.is_open(screen.screen_id()):
		var _pushed := stack.push(screen.screen_id())


func close() -> void:
	if stack != null and screen != null and stack.is_open(screen.screen_id()):
		var _popped := stack.pop(screen.screen_id())


func describe() -> Dictionary:
	var out := settings.describe() if settings != null else {}
	out["open"] = is_open()
	out["camera_bound"] = _camera != null
	return out
