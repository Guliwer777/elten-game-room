require_relative "audio_helpers"
include GameRoomTest::DuckAudio

GameRoomDuckRacing::AudioChallenges::TYPES.each do |reference, type|
  state = audio_start(type)
  assert_equal(state, audio_start(reference), "Reference number selected a different model")
  assert_equal(Marshal.dump(state), Marshal.dump(audio_start(type)), "Same seed differs")
  audio_reject(state) { AUDIO.submit(state, seat: "spectator", action: {kind: :answer, value: 5, press_id: 1}, now_ms: 0) }
  audio_reject(state) { AUDIO.submit(state, seat: "A", action: {kind: :unknown, press_id: 1}, now_ms: 0) }
  audio_reject(state) { AUDIO.submit(state, seat: "A", action: {kind: :answer, value: 5, press_id: 1}, now_ms: -1) }
  assert_equal(nil, AUDIO.stimulus(state, seat: "spectator"))
  view = AUDIO.view(state, seat: "A")
  assert_equal(false, view.key?(:private))
  assert_equal(false, view.key?(:scores))
  view[:seats] << "intruder"
  view[:public][:intruder] = true
  assert_equal(false, state[:seats].include?("intruder"))
  assert_equal(false, state[:public].key?(:intruder))
end
assert_raises(ArgumentError) { audio_start("not a challenge") }
assert_raises(ArgumentError) { audio_start("sound_memory", seats: ["A", "B", "C"]) }
assert_raises(ArgumentError) { audio_start("simon", seats: ["A", "A"]) }
assert_raises(ArgumentError) { audio_start("simon", seed: "31") }
assert_raises(ArgumentError) { audio_start("simon", now_ms: 0.1) }

# Counting starts its response clock after playback, with two submissions.
count = audio_start("count_ducks")
sequence = AUDIO.stimulus(count, seat: "A")[:events]
assert(sequence.length.between?(5, 15))
assert(sequence.each_cons(2).all? { |a, b| b[:offset_ms] > a[:offset_ms] + a[:duration_ms] })
assert_equal(sequence, AUDIO.stimulus(count, seat: "B")[:events])
audio_reject(count) { audio_press(count, "A", :answer, 100, value: sequence.length) }
assert_equal(false, AUDIO.expire(count, now_ms: 40_000), "Playback received an answer deadline")
assert(audio_ack(count, "A", 40_000))
assert_equal(60_000, audio_player(count, "A")[:deadline_ms])
assert(audio_press(count, "A", :replay, 41_000))
audio_reject(count) { audio_ack(count, "A", 41_001, playback_id: 1) }
assert(audio_ack(count, "A", 45_000))
assert_equal(60_000, audio_player(count, "A")[:deadline_ms], "Replay reset the answer deadline")
assert(audio_press(count, "A", :answer, 45_049, value: sequence.length))
assert_equal(50, count[:scores]["A"], "Elapsed time must round to integer tenths")
audio_reject(count) { audio_press(count, "A", :answer, 45_050, value: sequence.length) }
assert(audio_ack(count, "B", 40_000))
assert(audio_press(count, "B", :answer, 40_001, value: 99))
audio_reject(count) { audio_press(count, "B", :answer, 40_002, value: 99, repeat: true) }
assert_equal(1, audio_player(count, "B")[:attempts])
assert(audio_press(count, "B", :answer, 40_003, value: 98))
assert_equal(nil, count[:scores]["B"])
assert(count[:finished])
assert_equal(:attempts, count[:results]["B"][:reason])
assert_equal(count[:scores], AUDIO.view(count)[:scores])
boundary = audio_start("count_ducks")
assert(audio_ack(boundary, "A", 5_000))
audio_reject(boundary) { audio_press(boundary, "A", :answer, 25_000, value: sequence.length) }
assert(AUDIO.expire(boundary, now_ms: 25_000))
assert_equal(:timeout, boundary[:results]["A"][:reason])

# Sorting uses the shared seeded shuffle, not ELTEN's Array#shuffle. Only
# swaps change the arrangement; preview and invalid requests cannot move it.
order = audio_start("sound_order")
initial = audio_player(order, "A")[:arrangement].dup
assert_equal(initial, audio_player(order, "B")[:arrangement])
assert(initial != (1..8).to_a)
assert(audio_press(order, "A", :preview, 100, value: 1))
assert_equal(initial.first, AUDIO.stimulus(order, seat: "A")[:events][0][:tone])
assert_equal(initial, audio_player(order, "A")[:arrangement])
audio_reject(order) { audio_press(order, "A", :swap, 101, value: 1, other: 1) }
audio_reject(order) { audio_press(order, "A", :swap, 101, value: 1, other: 9) }
audio_reject(order) { audio_press(order, "A", :swap, 101, value: 1, other: 2, press_id: 0) }
now_ms = 100
8.times do |index|
  values = audio_player(order, "A")[:arrangement]
  next if values[index] == index + 1

  now_ms += 101
  assert(audio_press(order, "A", :swap, now_ms, value: index + 1, other: values.index(index + 1) + 1))
end
assert_equal(:correct, order[:results]["A"][:reason])
assert_equal(true, order[:results]["A"][:correct])
assert_equal(0, order[:results]["A"][:misplaced])
assert_equal(initial, audio_player(order, "B")[:arrangement], "One player changed another player's arrangement")
assert(!AUDIO.expire(order, now_ms: 45_000))
assert(order[:finished])
assert_equal(nil, order[:scores]["B"])

# Memory: direct 1..9,0 keys, two different available positions, and a turn
# change after every pair. The hidden layout does not appear in the view.
memory = audio_start("sound_memory")
owner = memory[:public][:turn]
other = (memory[:seats] - [owner]).first
layout = memory[:private][:pairs]
pairs = (0...10).group_by { |index| layout[index] }.values.map { |indexes| indexes.map { |index| index == 9 ? 0 : index + 1 } }
assert_equal(false, AUDIO.view(memory, seat: owner).key?(:layout))
audio_reject(memory) { audio_press(memory, other, :reveal, 10, value: pairs[0][0]) }
assert(audio_press(memory, owner, :reveal, 20, value: pairs[0][0]))
assert_equal(1, memory[:public][:revealed].length)
audio_reject(memory) { audio_press(memory, owner, :reveal, 21, value: pairs[0][0]) }
assert(audio_press(memory, owner, :reveal, 22, value: pairs[0][1]))
assert_equal(other, memory[:public][:turn], "A matching pair granted another turn")
assert_equal(1, memory[:public][:pairs][owner])
assert_equal([], memory[:public][:revealed])
audio_reject(memory) { audio_press(memory, other, :reveal, 23, value: pairs[0][0]) }
now_ms = 22
pairs.drop(1).each do |pair|
  current = memory[:public][:turn]
  pair.each do |position|
    now_ms += 10
    assert(audio_press(memory, current, :reveal, now_ms, value: position))
  end
end
assert(memory[:finished])
assert_equal(5, memory[:scores].values.sum)
assert_equal([2, 3], memory[:scores].values.sort)
assert_equal(10, memory[:public][:removed].uniq.length)
assert_equal(10, memory[:public][:sound_serial])
assert_equal(nil, memory[:public][:turn])

timeout = audio_start("sound_memory")
first = timeout[:public][:turn]
assert(audio_press(timeout, first, :reveal, 14_999, value: 0))
audio_reject(timeout) { audio_press(timeout, first, :reveal, 15_000, value: 1) }
assert(AUDIO.expire(timeout, now_ms: 15_000))
assert_equal([], timeout[:public][:revealed])
assert_equal((timeout[:seats] - [first]).first, timeout[:public][:turn])
audio_reject(timeout) { audio_press(timeout, timeout[:public][:turn], :reveal, 14_999, value: 1) }
assert(AUDIO.expire(timeout, now_ms: 45_000))
assert_equal((timeout[:seats] - [first]).first, timeout[:public][:turn])
assert_equal(60_000, timeout[:public][:turn_deadline_ms])
assert_equal(false, AUDIO.expire(timeout, now_ms: 45_000))
assert(AUDIO.expire(timeout, now_ms: 90_000))
assert(timeout[:finished])
assert_equal([0, 0], timeout[:scores].values)
assert_equal(false, AUDIO.expire(timeout, now_ms: 100_000))

# The 90-second overall timeout must beat a later per-turn deadline.
overlap = audio_start("sound_memory")
assert(AUDIO.expire(overlap, now_ms: 75_000))
pair = (0...10).group_by { |i| overlap[:private][:pairs][i] }.values.first
seat = overlap[:public][:turn]
pair.each_with_index { |index, i| assert(audio_press(overlap, seat, :reveal, 89_000 + i, value: index == 9 ? 0 : index + 1)) }
assert(overlap[:public][:turn_deadline_ms] > 90_000)
assert(AUDIO.expire(overlap, now_ms: 90_000))
assert(overlap[:finished])

# Stereo targets start their three seconds at actual onset, not at setup or
# at the end of a cue. Every target commits one digit or times out to zero.
targets = audio_start("hit_duck")
assert_equal(false, AUDIO.expire(targets, now_ms: 60_000))
audio_reject(targets) { audio_ack(targets, "A", 60_000) }
audio_reject(targets) { audio_press(targets, "A", :target, 60_000, value: 5) }
assert(audio_ack(targets, "A", 60_000, kind: :playback_started))
assert_equal(63_000, audio_player(targets, "A")[:deadline_ms])
audio_reject(targets) { audio_ack(targets, "A", 60_001, kind: :playback_started) }
assert(audio_ack(targets, "A", 60_100))
assert_equal(63_000, audio_player(targets, "A")[:deadline_ms])
first_target = targets[:private][:targets][0]
assert(audio_press(targets, "A", :target, 60_101, value: first_target))
audio_reject(targets) { audio_press(targets, "A", :target, 60_102, value: first_target, press_id: 0) }
audio_reject(targets) { audio_ack(targets, "A", 60_103, playback_id: 1) }
4.times do |index|
  now_ms = 61_000 + index * 1_000
  assert(audio_ack(targets, "A", now_ms, kind: :playback_started))
  assert(audio_press(targets, "A", :target, now_ms + 20, value: targets[:private][:targets][index + 1]))
end
assert_equal(Rational(100), targets[:scores]["A"])
5.times do |index|
  now_ms = 60_000 + index * 4_000
  assert(audio_ack(targets, "B", now_ms, kind: :playback_started))
  audio_reject(targets) { audio_press(targets, "B", :target, now_ms + 3_000, value: 5) }
  assert(AUDIO.expire(targets, now_ms: now_ms + 3_000))
end
assert(targets[:finished])
assert_equal(0, targets[:scores]["B"])

# Exercise each possible distance with generated, not manually injected,
# target positions. No reaction-time tiebreak enters the accuracy result.
9.times do |wanted|
  seed = (0...1_000).find { |candidate| audio_start("hit_duck", seed: candidate)[:private][:targets][0] == wanted + 1 }
  9.times do |answer|
    target = audio_start("hit_duck", seed: seed)
    assert(audio_ack(target, "A", 100, kind: :playback_started))
    assert(audio_press(target, "A", :target, 101, value: answer + 1))
    assert_equal([100 - 25 * (wanted - answer).abs, 0].max, audio_player(target, "A")[:target_scores][0])
  end
end
audio_report("Duck Racing count, sound ordering, memory, targets, privacy and invalid-input models")
