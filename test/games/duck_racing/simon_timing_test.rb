require_relative "audio_helpers"
require_relative "../../../games/duck_racing_support/settlement"
include GameRoomTest::DuckAudio

# Simon never times playback, and only whole completed levels contribute.
simon = audio_start("simon")
original = AUDIO.stimulus(simon, seat: "A")
assert_equal(1, original[:events].length)
audio_reject(simon) { audio_press(simon, "A", :tone, 1_000, value: original[:events][0][:tone]) }
assert_equal(false, AUDIO.expire(simon, now_ms: 100_000_000))
assert(audio_ack(simon, "A", 100_000_000))
audio_reject(simon) { audio_ack(simon, "A", 100_000_001, playback_id: original[:id]) }
assert(audio_press(simon, "A", :tone, 100_004_999, value: original[:events][0][:tone]))
assert_equal(1, audio_player(simon, "A")[:completed_length])
assert_equal(nil, audio_player(simon, "A")[:deadline_ms])
original = AUDIO.stimulus(simon, seat: "A")
assert_equal(2, original[:events].length)
assert(audio_ack(simon, "A", 100_010_000))
assert(audio_press(simon, "A", :tone, 100_014_999, value: original[:events][0][:tone]))
assert_equal(100_019_999, audio_player(simon, "A")[:deadline_ms])
audio_reject(simon) { audio_press(simon, "A", :tone, 100_015_000, value: original[:events][1][:tone], repeat: true) }
assert_equal(100_019_999, audio_player(simon, "A")[:deadline_ms])
audio_reject(simon) { audio_press(simon, "A", :tone, 100_015_000, value: original[:events][1][:tone], press_id: 0) }
assert_equal(false, AUDIO.expire(simon, now_ms: 100_019_998))
audio_reject(simon) { audio_press(simon, "A", :tone, 100_019_999, value: original[:events][1][:tone]) }
assert(AUDIO.expire(simon, now_ms: 100_019_999))
assert_equal(1, simon[:scores]["A"], "A partial second sequence must preserve the first score")
assert_equal(false, simon[:finished], "The listening opponent was prematurely eliminated")

# A sole remaining racer continues beyond thirty sounds and beyond every
# opponent's score. Finishing one player does not settle the challenge.
long_game = audio_start("simon")
first = AUDIO.stimulus(long_game, seat: "B")[:events][0][:tone]
assert(audio_ack(long_game, "B", 1_000))
assert(audio_press(long_game, "B", :tone, 1_001, value: first % 5 + 1))
assert_equal(0, long_game[:scores]["B"])
assert_equal(false, long_game[:finished])
now_ms = 0
34.times do
  now_ms = audio_simon_level(long_game, "A", now_ms)
  assert_equal(false, long_game[:finished], "Being the sole survivor ended Simon")
end
assert_equal(34, audio_player(long_game, "A")[:completed_length])
assert_equal(35, AUDIO.stimulus(long_game, seat: "A")[:events].length)
assert_equal(nil, audio_player(long_game, "A")[:deadline_ms])
assert_equal(false, AUDIO.expire(long_game, now_ms: now_ms + 1_000_000))
assert(audio_ack(long_game, "A", now_ms + 1_000_000))
prefix = long_game[:private][:sequence]
assert(audio_press(long_game, "A", :tone, now_ms + 1_000_001, value: prefix[0]))
assert(audio_press(long_game, "A", :tone, now_ms + 1_000_002, value: prefix[1] % 5 + 1))
assert(long_game[:finished])
assert_equal(34, long_game[:scores]["A"], "Partial final sequence inflated the completed-length score")
audio_reject(long_game) { audio_press(long_game, "A", :tone, now_ms + 1_000_003, value: 1) }

# A slower player follows exactly the same growing prefix. Interleaving
# levels, saving the model and rejected presses cannot perturb its draws.
alternating = audio_start("simon", seed: 87)
sequential = audio_start("simon", seed: 87)
times = {"A" => 0, "B" => 0}
8.times do
  %w[A B].each { |seat| times[seat] = audio_simon_level(alternating, seat, times[seat]) }
end
%w[B A].each do |seat|
  time = 0
  8.times do |completed|
    notes = AUDIO.stimulus(sequential, seat: seat)[:events]
    assert_equal(completed + 1, notes.length)
    assert_equal(Array.new(completed, 500 - completed * 10),
      notes.each_cons(2).map { |first, second| second[:offset_ms] - first[:offset_ms] },
      "The other player's longer prefix sped up this player")
    time = audio_simon_level(sequential, seat, time)
  end
end
assert_equal(alternating[:private][:sequence], sequential[:private][:sequence])
assert_equal(AUDIO.stimulus(alternating, seat: "A")[:events], AUDIO.stimulus(sequential, seat: "B")[:events])
restored = Marshal.load(Marshal.dump(alternating))
time_a = audio_simon_level(alternating, "A", times["A"])
audio_simon_level(restored, "A", times["A"])
assert_equal(alternating, restored, "Restored state produced a different continuation")
audio_reject(alternating) { audio_press(alternating, "A", :tone, time_a + 1, value: 6) }
assert_equal(restored[:private][:sequence], alternating[:private][:sequence])

# Agreed 16-versus-10 score is settled only after both attempts end, with
# a six-feather difference rather than a generic fixed stake.
gap = audio_start("simon")
{"A" => 16, "B" => 10}.each do |seat, length|
  time = 0
  length.times { time = audio_simon_level(gap, seat, time) }
  assert(audio_ack(gap, seat, time + 50_000))
  assert(audio_press(gap, seat, :tone, time + 50_001, value: gap[:private][:sequence][0] % 5 + 1))
  assert_equal(length, gap[:scores][seat])
  assert_equal(seat == "B", gap[:finished])
end
settled = GameRoomDuckRacing::Settlement.difference(balances: {"A" => 20, "B" => 20}, scores: gap[:scores])
assert_equal({"A" => 26, "B" => 14}, settled.balances)
audio_report("Simon playback, inactivity, unlimited length, shared tempo, deterministic replay and scoring")
