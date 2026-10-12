require_relative "audio_helpers"
include GameRoomTest::DuckAudio

# The caller cannot mutate model identity or recorded responses after return.
type = +"rhythm"
seats = [+"A", +"B"]
state = audio_start(type, seats: seats)
type.replace("simon")
seats[0].replace("outside")
seats << "C"
assert_equal("rhythm", state[:type])
assert_equal(%w[A B], state[:seats])
assert(audio_ack(state, "A", 10_000))
assert(audio_press(state, "A", :begin, 10_001))
tone = +"f"
assert(audio_press(state, "A", :tone, 10_002, value: tone))
tone.replace("j")
assert_equal("f", audio_player(state, "A")[:presses][0][:tone])
stimulus = AUDIO.stimulus(state, seat: "B")
stimulus[:events][0][:tone] = "outside"
stimulus[:events].clear
assert(AUDIO.stimulus(state, seat: "B")[:events].length >= 6)
assert(["f", "j"].include?(AUDIO.stimulus(state, seat: "B")[:events][0][:tone]))

before = Marshal.dump(state)
[-1, nil, 0.5, Float::NAN, "10000"].each do |time|
  assert_equal(false, AUDIO.expire(state, now_ms: time))
  assert_equal(before, Marshal.dump(state))
  audio_reject(state) { AUDIO.submit(state, seat: "A", action: {kind: :tone, value: "f", press_id: 2}, now_ms: time) }
end
audio_reject(state) { AUDIO.submit(state, seat: "A", action: nil, now_ms: 11_000) }
audio_reject(state) { AUDIO.submit(state, seat: "A", action: {kind: :tone, value: "f"}, now_ms: 11_000) }
audio_reject(state) { AUDIO.submit(state, seat: "A", action: {kind: :tone, value: "f", press_id: 2}, now_ms: 10_001) }

# Eight independent count attempts, exact tenth-second rounding and private
# results until the final player ends. The seed is never a public field.
seats = (0...8).to_a
count = audio_start("count_ducks", seats: seats)
answer = count[:private][:count]
[0, 49, 50, 149, 150, 199, 250, 251].each_with_index do |elapsed, seat|
  assert(audio_ack(count, seat, 10_000))
  assert(audio_press(count, seat, :answer, 10_000 + elapsed, value: answer))
  assert_equal((elapsed + 50) / 100, count[:scores][seat])
  assert_equal(seat == 7, count[:finished])
  unless seat == 7
    public = AUDIO.view(count, seat: 7)
    assert_equal(false, public.key?(:scores))
    assert_equal(false, public[:own].key?(:result))
    assert_equal(false, public.key?(:seed))
  end
end
assert_equal(8, AUDIO.view(count)[:scores].size)

%w[count_ducks rhythm sound_order simon hit_duck].each do |type_id|
  assert_equal(8, audio_start(type_id, seats: seats)[:seats].size)
  assert_raises(ArgumentError) { audio_start(type_id, seats: (0...9).to_a) }
  assert_raises(ArgumentError) { audio_start(type_id, seats: [0]) }
end

# Each generated stimulus respects its bounds and has the same content for
# all participants. Target positions remain private until they are played.
100.times do |seed|
  count = audio_start("count_ducks", seed: seed)
  count_events = AUDIO.stimulus(count, seat: "A")[:events]
  assert(count_events.length.between?(5, 15))
  assert(count_events.each_cons(2).all? { |first, second| second[:offset_ms] >= first[:offset_ms] + first[:duration_ms] })
  rhythm = audio_start("rhythm", seed: seed)
  beats = AUDIO.stimulus(rhythm, seat: "A")[:events]
  assert(beats.length.between?(6, 10))
  assert(beats.all? { |beat| %w[f j].include?(beat[:tone]) })
  assert(beats.each_cons(2).all? { |first, second| (second[:offset_ms] - first[:offset_ms]).between?(250, 900) })
  memory = audio_start("sound_memory", seed: seed)
  assert_equal([2] * 5, memory[:private][:pairs].tally.values.sort)
  order = audio_start("sound_order", seed: seed)
  assert_equal((1..8).to_a, audio_player(order, "A")[:arrangement].sort)
  assert(audio_player(order, "A")[:arrangement] != (1..8).to_a)
  targets = audio_start("hit_duck", seed: seed)
  assert(targets[:private][:targets].all? { |value| value.between?(1, 9) })
  assert_equal(1, AUDIO.stimulus(targets, seat: "A")[:events].length)
  assert_equal(false, AUDIO.view(targets, seat: "A").key?(:targets))
end

# A wrong memory pair does not survive into the next turn, but each digit
# still produces its own sound event for the transition presenter.
memory = audio_start("sound_memory")
layout = memory[:private][:pairs]
first_index = 0
second_index = (1...10).find { |index| layout[index] != layout[first_index] }
seat = memory[:public][:turn]
assert(audio_press(memory, seat, :reveal, 10, value: first_index + 1))
first_event = AUDIO.view(memory)[:public][:sound_event]
assert(audio_press(memory, seat, :reveal, 20, value: second_index == 9 ? 0 : second_index + 1))
second_event = AUDIO.view(memory)[:public][:sound_event]
assert_equal(1, first_event[:id])
assert_equal(2, second_event[:id])
assert(first_event[:tone] != second_event[:tone])
assert_equal([], memory[:public][:revealed])
assert_equal([], memory[:public][:removed])
assert_equal([0, 0], memory[:public][:pairs].values)
assert_equal(false, memory[:finished])
assert(memory[:public][:turn] != seat)

# Every target scores once. All eight players can progress at different
# speeds without changing one another's stimulus or accuracy.
targets = audio_start("hit_duck", seats: seats)
seats.each do |seat|
  5.times do |index|
    start_ms = 1_000 + index * 4_000 + seat * 10
    cue = AUDIO.stimulus(targets, seat: seat)
    assert_equal(Rational(targets[:private][:targets][index] - 5, 4), cue[:events][0][:pan])
    assert(audio_ack(targets, seat, start_ms, kind: :playback_started))
    assert(audio_press(targets, seat, :target, start_ms + seat * 100, value: targets[:private][:targets][index]))
    audio_reject(targets) { AUDIO.submit(targets, seat: seat, action: {kind: :playback_finished, playback_id: cue[:id]}, now_ms: start_ms + seat * 100 + 1) }
  end
  assert_equal(100, targets[:scores][seat])
end
assert(targets[:finished])
assert_equal([100] * 8, targets[:scores].values)
audio_report("Duck Racing audio model ownership, eight-player isolation, stimulus bounds and replay contracts")
