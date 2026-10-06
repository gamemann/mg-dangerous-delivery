extends DotGameServices

## Chat, voice and moderation over dot-game's base: what this game decides about them.
##
## [b]Solo does not touch any of it.[/b] The brief is that a solo player still plays on the
## server and chats; solo is about trucks, not people.

const DdGame := preload("dd_game.gd")

const CH_ALL := &"all"
const CH_ADMIN := &"admin"
const CH_WHISPER := &"whisper"

## Voice from a truck reaches this far, for the proximity channel. Long, because a road is long
## and two trucks a bend apart are a conversation.
const PROXIMITY_RANGE := 60.0


func _services_name() -> String:
	return "delivery"


func _chat_rules() -> Object:
	var rules := DotChatRules.new()
	rules.max_length = 160
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 20
	rules.burst = 4.0
	rules.flood_penalty_sec = 10.0
	rules.command_prefixes = PackedStringArray(["!", "/"])
	rules.broadcast_unknown_commands = false
	rules.history_limit = 300
	return rules


func _chat_channels() -> Array:
	var out: Array[DotChatChannel] = []
	var everyone := DotChatChannel.make(CH_ALL, "All", DotChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	# Longer than a round game's: there are no rounds, and somebody arriving mid-conversation
	# on a server people drive on for an hour wants the last few lines.
	everyone.backlog = 20
	everyone.history_limit = 300
	out.append(everyone)
	var admin := DotChatChannel.make(CH_ADMIN, "Admin", DotChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)
	var whisper := DotChatChannel.make(CH_WHISPER, "Whisper", DotChatChannel.Scope.DIRECT)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)
	return out


func _voice_config() -> Object:
	var config := DotVoiceConfig.new()
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.proximity_range = PROXIMITY_RANGE
	config.max_bytes_per_second = 6144
	return config


## Where a peer's truck is, or the origin for somebody in the lot.
func _position_of(peer_id: int) -> Vector3:
	var world := game as DdGame
	var key: StringName = bridge_key(peer_id)

	if world == null or key == &"":
		return Vector3.ZERO

	var driver: DdGame.Driver = world.drivers.get(key, null)
	return (driver.truck as Node3D).global_position if driver != null and driver.truck != null else Vector3.ZERO


func bridge_key(peer_id: int) -> StringName:
	return link.get("bridge").call("key_of_peer", peer_id) if link != null and link.get("bridge") != null else &""
