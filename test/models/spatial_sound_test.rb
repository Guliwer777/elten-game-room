require_relative "../../lib/game_sounds"
require_relative "../../lib/game_room_preferences"

def assert(value, message); raise message unless value; end

def near?(actual, expected)
  actual != nil && actual.zip(expected).all? { |value, wanted| (value - wanted).abs < 1e-9 }
end

seat = GameRoomSpatialSound.method(:position)
left, front, right, back = [-1.0, 0.0, 0.0], [0.0, 0.0, -1.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]

assert(seat.call(%w[Ala Bob], "ala", "Ala").nil?, "Own sound left the centre")
lifted = [0.0, Math.sin(Math::PI / 36), -Math.cos(Math::PI / 36)]
assert(near?(seat.call(%w[Ala Bob], "Ala", "bob"), lifted), "Two-player opponent is not in front, slightly raised")
assert(near?(seat.call(%w[Bob Ala], "Ala", "Bob"), lifted), "Second seat hears the first player off-centre")
assert((GameRoomSpatialSound.gain(seat.call(%w[Ala Bob], "Ala", "Bob")) - GameRoomSpatialSound::FRONT_GAIN).abs < 1e-9,
  "Raised opponent lost the front lift")
four = %w[Ala Bob Cyd Dan]
half = Math.sqrt(3) / 2
left, right = [-half, 0.0, -0.5], [half, 0.0, -0.5]
assert(near?(seat.call(four, "Ala", "Bob"), left) && near?(seat.call(four, "Ala", "Cyd"), lifted) &&
  near?(seat.call(four, "Ala", "Dan"), right), "Four players are not at 10, 12 (raised) and 2 o'clock")
six = %w[A B C D E F]
assert(near?(seat.call(six, "A", "D"), lifted) && seat.call(six, "A", "C")[1] == 0.0 &&
  (GameRoomSpatialSound.gain(seat.call(four, "Ala", "Cyd")) - GameRoomSpatialSound::FRONT_GAIN).abs < 1e-9 &&
  (GameRoomSpatialSound.gain(seat.call(six, "A", "D")) - GameRoomSpatialSound::FRONT_GAIN).abs < 1e-9,
  "Seat across a four or six table is not raised with the table front gain")
assert(near?(seat.call(four, "Cyd", "Dan"), left) && near?(seat.call(four, "Cyd", "Bob"), right),
  "Clock does not rotate with the listener's seat")
eight = %w[A B C D E F G H]
arc = eight.drop(1).map { |name| seat.call(eight, "A", name) }
assert(arc.all? { |x, _, z| z < 0 } && arc.each_cons(2).all? { |a, b| a[0] < b[0] } &&
  arc.first[0] > -1 && near?(arc[3], front) && !GameRoomSpatialSound.distant?(arc[3]),
  "Eight players are not packed left to right in front at ear level")
three = seat.call(%w[Ala Bob Cyd], "Ala", "Bob")
other = seat.call(%w[Ala Bob Cyd], "Ala", "Cyd")
assert(three[0] < -0.4 && three[2] < -0.8 && other[0] > 0.4 && other[2] < -0.8,
  "Three players are not placed towards the front-left and front-right")
assert(near?(seat.call(four, "Spectator", "Ala"), back) && near?(seat.call(four, "Spectator", "Bob"), left),
  "Spectator does not listen from the first seat")
assert(seat.call(four, "Ala", "Eve").nil? && seat.call(four, "Ala", "").nil? && seat.call(["Ala"], "Bob", "Ala").nil?,
  "Unknown or solo source was placed")
assert(GameRoomSpatialSound.cue_position("win_party", left).nil? && GameRoomSpatialSound.cue_position("poker_pot", left).nil? &&
  GameRoomSpatialSound.cue_position("poker_raise", left) == left && GameRoomSpatialSound.cue_position("play", left) == left,
  "Table-wide cues are not centred")

# Playback: a placed cue uses the host's spatial voice, quieter; failure stays audible.
class SpatialProgram
  attr_reader :calls
  attr_accessor :hrtf, :fail_spatial
  def initialize; @calls, @hrtf = [], true; end
  def play_sound_from_asset(name, **options)
    @calls << [name, options]
    return nil if fail_spatial && options.key?(:spatial)
    Object.new
  end
  def game_room_sound_volume(_name); 0.5; end
  def game_room_hrtf?(game_id); hrtf && game_id == "uno"; end
end
program = SpatialProgram.new
GameRoomSounds.play(program, "play", spatial: left)
name, options = program.calls.last
assert(name == "play" && options[:spatial] == left && (options[:volume] - 0.4).abs < 5e-3, "Placed cue was not spatial")
GameRoomSounds.play(program, "play", spatial: front)
assert((program.calls.last.last[:volume] - 0.675).abs < 1e-9, "Seat straight ahead was not lifted")
assert(GameRoomSpatialSound.gain(seat.call(four, "Ala", "Bob")) < 0.83, "Side seats were lifted")

GameRoomSounds.play(program, "play")
assert(!program.calls.last.last.key?(:spatial) && program.calls.last.last[:volume] == 0.5, "Centred cue changed")
GameRoomSounds.play(program, "ding", spatial: left)
assert(!program.calls.last.last.key?(:spatial), "Turn signal was placed")
program.fail_spatial = true
program.calls.clear
GameRoomSounds.play(program, "play", spatial: left)
assert(program.calls.length == 2 && !program.calls.last.last.key?(:spatial), "Failed 3D voice was silent")
program.fail_spatial = false

# The lone opponent gets distance effects attached before its voice starts.
class BassFXEffect; def self.available?; true; end; end
class ReverbEffect < BassFXEffect; attr_reader :options; def initialize(**options); @options = options; end; end
class BiquadFilterEffect < ReverbEffect; end
class DistantSound
  attr_reader :effects, :played_with
  attr_accessor :volume
  def initialize; @effects = []; end
  def effect_add(effect); @effects << effect; end
  def close; @closed = true; end
  def closed?; @closed == true; end
end
class DistantPool
  attr_reader :played
  def play(sound); @played = sound; sound; end
end
class DistantProgram < SpatialProgram
  attr_reader :pool, :created
  attr_accessor :broken
  def initialize; super; @pool = DistantPool.new; end
  def sound_pool; @pool; end
  def create_spatial_sound_from_asset(name, position:)
    @created = [name, position, DistantSound.new]
    raise "no voice" if broken
    @created.last
  end
end
distant = DistantProgram.new
opponent = seat.call(%w[Ala Bob], "Ala", "Bob")
GameRoomSounds.play(distant, "play", spatial: opponent)
voice = distant.created.last
assert(distant.pool.played.equal?(voice) && distant.calls.empty? && distant.created[1] == opponent &&
  voice.effects.map(&:class) == [BiquadFilterEffect, ReverbEffect] && (voice.volume - 0.675).abs < 1e-9,
  "Lone opponent was not played farther away with filter and room")
GameRoomSounds.play(distant, "play", spatial: seat.call(four, "Ala", "Cyd"))
assert(distant.created.last.effects.length == 2 && (distant.created.last.volume - 0.675).abs < 1e-9, "Seat across a four-player table was not played farther away")
GameRoomSounds.play(distant, "play", spatial: front)
assert(distant.calls.last.last[:spatial] == front, "Seat ahead at a bigger table got distance effects")
distant.broken = true
GameRoomSounds.play(distant, "play", spatial: opponent)
assert(distant.calls.last.last[:spatial] == opponent, "Failed distant voice did not fall back to plain 3D")

# Event placement follows the authenticated actor and the game's declaration.
Game = Struct.new(:id, :spatial) do
  def player_spatial_audio?; spatial; end
end
Replay = Struct.new(:players, :current_player)
repository = Object.new
def repository.actor_of(event, _session = nil); event["actor"].to_s; end
GameRoomSpatialSound.instance_variable_set(:@engine_ready, true)
after = Replay.new(four, "Cyd")
place = ->(game, actor, player = program) do
  GameRoomSpatialSound.event_position(player, game, { "actor" => actor }, Replay.new(four, "Bob"), after, repository, "Ala", {})
end
uno = Game.new("uno", true)
assert(near?(place.call(uno, "Dan"), right), "Event actor was not placed")
assert(near?(place.call(uno, ""), left), "Missing actor did not fall back to the moving player")
program.hrtf = false
assert(place.call(uno, "Dan").nil?, "Disabled setting still placed sounds")
program.hrtf = true
assert(place.call(Game.new("uno", false), "Dan").nil? && place.call(Game.new("chess", true), "Dan").nil?,
  "Audio game or unchecked game was placed")
GameRoomSpatialSound.instance_variable_set(:@engine_ready, false)
assert(place.call(uno, "Dan").nil?, "Missing HRTF engine still placed sounds")

# Preferences: on by default, a saved opt-out stays; every game, including later additions, starts checked.
ids = %w[uno chess]
defaults = GameRoomPreferences.normalize({}, ids)
assert(defaults["hrtf_enabled"] == true && defaults["hrtf_games"] == ids, "Wrong 3D sound defaults")
assert(GameRoomPreferences.normalize({ "hrtf_enabled" => false }, ids)["hrtf_enabled"] == false, "Saved opt-out was lost")
saved = GameRoomPreferences.normalize({ "hrtf_enabled" => true, "hrtf_games" => [], "hrtf_known_games" => ids }, ids + ["war"])
assert(saved["hrtf_games"] == ["war"] && saved["hrtf_enabled"], "Opt-outs lost or new game not checked")
assert(GameRoomPreferences.hrtf_game?(saved, "war") && !GameRoomPreferences.hrtf_game?(saved, "uno") &&
  !GameRoomPreferences.hrtf_game?(defaults.merge("hrtf_enabled" => false), "uno"), "hrtf_game? ignored the switch or list")

puts "PASS 3D sound: clock seats, spectator, centred cues, spatial playback/fallback, event actor, settings gates, preferences"
