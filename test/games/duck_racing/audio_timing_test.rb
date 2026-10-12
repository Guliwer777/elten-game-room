require_relative "audio_helpers"
include GameRoomTest::DuckAudio

# Exact boundary checks for rhythm intervals, including missing intervals.
[[0, 2], [80, 2], [81, 1], [160, 1], [161, 0], [-80, 2], [-81, 1], [-160, 1], [-161, 0]].each do |error, credit|
  state = audio_start("rhythm")
  expected = AUDIO.stimulus(state, seat: "A")[:events]
  assert(expected.length.between?(6, 10))
  assert_equal(expected, AUDIO.stimulus(state, seat: "B")[:events])
  assert(audio_ack(state, "A", 12_000))
  assert_equal(27_000, audio_player(state, "A")[:deadline_ms])
  assert(audio_press(state, "A", :begin, 26_999))
  # A late first press is not a rhythmic mistake; all later gaps are compared.
  now_ms = 29_998
  expected.each_with_index do |event, index|
    now_ms += expected[index][:offset_ms] - expected[index - 1][:offset_ms] + (index == 1 ? error : 0) unless index.zero?
    assert(audio_press(state, "A", :tone, now_ms, value: event[:tone]))
  end
  expected_score = 50 + Rational(25 * (2 * (expected.length - 2) + credit), expected.length - 1)
  assert_equal(expected_score, state[:scores]["A"], "Rhythm interval boundary #{error} was wrong")
end

rhythm = audio_start("rhythm", seats: ["A", "B", "C"])
events = AUDIO.stimulus(rhythm, seat: "A")[:events]
assert_equal(false, AUDIO.expire(rhythm, now_ms: 100_000), "Rhythm readiness expired before playback finished")
assert(audio_ack(rhythm, "A", 100_000))
assert(audio_press(rhythm, "A", :replay, 100_100))
assert_equal(0, audio_player(rhythm, "A")[:replays_left])
audio_reject(rhythm) { audio_press(rhythm, "A", :begin, 100_101) }
assert(audio_ack(rhythm, "A", 110_000))
assert_equal(115_000, audio_player(rhythm, "A")[:deadline_ms])
audio_reject(rhythm) { audio_press(rhythm, "A", :replay, 110_001) }
assert(audio_press(rhythm, "A", :begin, 110_002))
assert(audio_press(rhythm, "A", :tone, 110_003, value: events[0][:tone]))
audio_reject(rhythm) { audio_press(rhythm, "A", :tone, 110_004, value: events[1][:tone], repeat: true) }
audio_reject(rhythm) { audio_press(rhythm, "A", :tone, 110_004, value: events[1][:tone], press_id: 2) }
assert_equal(1, audio_player(rhythm, "A")[:presses].length)
audio_reject(rhythm) { audio_press(rhythm, "A", :tone, 113_003, value: events[1][:tone]) }
assert(AUDIO.expire(rhythm, now_ms: 113_003))
assert_equal(Rational(50, events.length), rhythm[:scores]["A"], "Missing tones/intervals earned points")
assert(audio_ack(rhythm, "B", 100_000))
audio_reject(rhythm) { audio_press(rhythm, "B", :begin, 115_000) }
assert(AUDIO.expire(rhythm, now_ms: 115_000))
assert_equal(0, rhythm[:scores]["B"])
assert(audio_ack(rhythm, "C", 100_000))
assert(audio_press(rhythm, "C", :begin, 100_001))
assert(AUDIO.expire(rhythm, now_ms: 103_001))
assert_equal(0, rhythm[:scores]["C"])
assert(rhythm[:finished])

# Wrong tones still consume their positions. Perfect gaps alone earn 50%.
wrong = audio_start("rhythm")
notes = AUDIO.stimulus(wrong, seat: "A")[:events]
assert(audio_ack(wrong, "A", 20_000))
assert(audio_press(wrong, "A", :begin, 20_001))
notes.each { |note| assert(audio_press(wrong, "A", :tone, 20_002 + note[:offset_ms], value: note[:tone] == "f" ? "j" : "f")) }
assert_equal(50, wrong[:scores]["A"])
audio_reject(wrong) { audio_press(wrong, "A", :tone, 40_000, value: notes[0][:tone]) }

audio_report("Duck Racing rhythm interval boundaries and missing tones")
