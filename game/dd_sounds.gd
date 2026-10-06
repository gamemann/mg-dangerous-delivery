extends Node

## What driving sounds like: an engine whose pitch follows the speed and whose load follows the
## throttle, a hiss when the brakes go on, rain on the roof, a gust of wind, rock coming down,
## and a chime at the depot. Synthesised, so the game carries no audio files.
##
## [b]Fed, never asking[/b], like the HUD: [DdClient] sets [member speed], [member throttle],
## [member braking] and [member weather] every frame and calls the one-shots when the world says
## something happened. The engine of a truck you are not driving is not drawn here; it would be
## a positional player on each mirrored truck, and is on the list.

const RATE := 22050

## m/s, signed: forward is positive.
var speed: float = 0.0
## 0 to 1: how hard the engine is being asked.
var throttle: float = 0.0
var braking: bool = false
## {"sky": 0 clear / 1 rain / 2 snow, "wind": bool}.
var weather: Dictionary = {}
## Whether anything plays at all: off in the garage.
var driving: bool = false

var _engine: AudioStreamPlayer = null
var _rain: AudioStreamPlayer = null
var _wind: AudioStreamPlayer = null
var _hiss: AudioStreamPlayer = null
var _rumble: AudioStreamPlayer = null
var _chime: AudioStreamPlayer = null
var _was_braking := false


func _ready() -> void:
	_engine = _player(_engine_loop(), true)
	_rain = _player(_noise_loop(0.9, 0.0), true)
	_wind = _player(_noise_loop(0.15, 1.0), true)
	_hiss = _player(_hiss_burst(), false)
	_rumble = _player(_rumble_burst(), false)
	_chime = _player(_chime_tone(), false)


func _player(stream: AudioStream, loop: bool) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = -80.0 if loop else -4.0
	add_child(p)

	if loop:
		p.play()

	return p


func _process(delta: float) -> void:
	var k := 1.0 - exp(-delta * 8.0)
	var on := 1.0 if driving else 0.0
	# Idle at a quarter pitch, climbing with speed: a diesel never revs like a car.
	_engine.pitch_scale = lerpf(_engine.pitch_scale, 0.55 + clampf(absf(speed) / 22.0, 0.0, 1.0) * 0.9, k)
	_engine.volume_db = lerpf(_engine.volume_db, (-14.0 + 8.0 * clampf(throttle, 0.0, 1.0)) if driving else -80.0, k)
	var sky := int(weather.get("sky", 0))
	_rain.volume_db = lerpf(_rain.volume_db, -12.0 if driving and sky == 1 else -80.0, k * 0.3)
	_wind.volume_db = lerpf(_wind.volume_db, -10.0 if driving and bool(weather.get("wind", false)) else -80.0, k * 0.3)

	if braking and not _was_braking and absf(speed) > 3.0 and on > 0.0:
		_hiss.play()

	_was_braking = braking


func rock() -> void:
	_rumble.play()


func delivered() -> void:
	_chime.play()


# --- The synthesis -------------------------------------------------------------

static func _wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)

	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.data = data

	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = samples.size()

	return wav


## A diesel: a low fundamental with odd harmonics and a firing-order pulse. One second, whole
## cycles of everything, so it loops without a click; pitch_scale does the revving.
static func _engine_loop() -> AudioStreamWAV:
	var n := RATE
	var out := PackedFloat32Array()
	out.resize(n)

	for i in n:
		var t := float(i) / RATE
		var pulse := 0.6 + 0.4 * sin(TAU * 25.0 * t)
		out[i] = (sin(TAU * 50.0 * t) * 0.5 + sin(TAU * 150.0 * t) * 0.25 + sin(TAU * 250.0 * t) * 0.12) * pulse * 0.6

	return _wav(out, true)


## Filtered noise, looped: [param smooth] near 1 is a low roar (wind), near 0 a hiss (rain).
static func _noise_loop(brightness: float, swell: float) -> AudioStreamWAV:
	var n := RATE * 2
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var last := 0.0

	for i in n:
		var t := float(i) / RATE
		var white := rng.randf_range(-1.0, 1.0)
		last = lerpf(last, white, brightness)
		var level := 1.0 - swell * 0.5 * (1.0 + sin(TAU * 0.5 * t))
		out[i] = last * 0.5 * level

	# Fade the seam so the loop does not tick.
	for i in 400:
		var f := float(i) / 400.0
		out[i] *= f
		out[n - 1 - i] *= f

	return _wav(out, true)


static func _hiss_burst() -> AudioStreamWAV:
	var n := int(RATE * 0.5)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11

	for i in n:
		var t := float(i) / RATE
		out[i] = rng.randf_range(-1.0, 1.0) * exp(-t * 6.0) * 0.35

	return _wav(out, false)


static func _rumble_burst() -> AudioStreamWAV:
	var n := int(RATE * 1.6)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	var last := 0.0

	for i in n:
		var t := float(i) / RATE
		last = lerpf(last, rng.randf_range(-1.0, 1.0), 0.05)
		out[i] = (last * 1.6 + sin(TAU * 38.0 * t) * 0.3) * exp(-t * 1.6) * minf(t * 10.0, 1.0)

	return _wav(out, false)


static func _chime_tone() -> AudioStreamWAV:
	var n := int(RATE * 0.9)
	var out := PackedFloat32Array()
	out.resize(n)

	for i in n:
		var t := float(i) / RATE
		var note := 660.0 if t < 0.25 else 880.0
		out[i] = sin(TAU * note * t) * exp(-fmod(t, 0.25) * 5.0) * 0.4

	return _wav(out, false)
