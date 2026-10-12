require_relative '../../support/duck_game_adapter'
include DuckGameAdapterTest

h = Harness.new(kind: 'simon')
h.open_round
h.begin_round
challenge = h.replay.state[:round][:challenge]
traces = challenge[:participants].to_h do |seat|
  trace = LOGIC::ChallengeTrace.new(challenge, seat: seat, resources: h.resources)
  now, press = 0, 0
  loop do
    cue = LOGIC::ChallengeEngine.stimulus(trace.state, seat: seat)
    events = cue[:events]
    now = cue[:requested_ms] + events.last[:offset_ms] + events.last[:duration_ms] + 20
    assert(trace.submit({kind: :playback_finished, playback_id: cue[:id]}, at: now))
    if events.length > 9 + seat
      assert(trace.submit({kind: :tone, value: events.first[:tone] % 5 + 1, press_id: press += 1}, at: now += 100))
      break
    end
    events.each do |event|
      assert(trace.submit({kind: :tone, value: event[:tone], press_id: press += 1}, at: now += 100))
    end
  end
  assert(trace.finished?)
  [seat, trace.snapshot]
end
now = h.replay.state[:round][:started_at] + traces.values.map { |trace| trace['finished_at'] }.max + 10
traces.each do |seat, trace|
  h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace},
    actor: h.players[seat], at: now)
end
h.accept({'action' => 'advance', 'challenge' => challenge[:id]}, at: now + 10)
replay = h.replay
pending = h.game.automatic_action(replay, 'Alice', context: h.context('Alice'))
assert_equal('reveal', pending['action'])
original_page = Marshal.load(Marshal.dump(pending.fetch('page')))
assert(LOGIC::PrivateRound.reveal_page_size(original_page) > 200)

# The selection was prepared under the old grant/epoch. The normal write
# boundary calls action_for again with current metadata and must reduce that
# one unsent page, without mutating the queued selection or its committed hash.
h.session['__control_epoch'] = 'e' * 64
limit = {'duck_stack_entry_bytes' => 1536}
plan = h.accept(pending, actor: 'Alice', local: limit)
data = h.decode(h.events.last(plan.events.length)).first.fetch(0)
assert(data['page'].is_a?(Array), 'The native packet must use the compact wire page')
data['page'] = LOGIC::PrivateTraceStream.normalize_page(data['page'], session_id: original_page['session'],
  round_id: original_page['round'], seat: original_page['seat'])
assert(data['page'], 'The compact page lost its scope')
assert(LOGIC::PrivateRound.reveal_page_size(data['page']) < LOGIC::PrivateRound.reveal_page_size(original_page))
assert_equal(original_page, pending['page'], 'Preflight mutated the queued selection')
assert_equal(original_page['offset'], data['page']['offset'])
assert_equal(original_page['total'], data['page']['total'])
assert_equal(original_page['unpacked_bytes'], data['page']['unpacked_bytes'])
assert_equal(original_page['codec'], data['page']['codec'])
100.times do
  break if h.replay.state[:last_resolution]
  h.players.each do |actor|
    break if h.replay.state[:last_resolution]
    current = h.replay
    context = h.context(actor, local: limit)
    selection = h.game.automatic_action(current, actor, context: context)
    h.accept(selection, actor: actor, local: limit) if selection
  end
end
resolution = h.replay.state[:last_resolution]
assert(resolution && resolution[:settlement], 'Send-boundary repartitioning did not complete the verified attempts')
assert_equal(9, resolution[:results][0][:score])
assert_equal(10, resolution[:results][1][:score])
puts 'PASS Duck write-boundary revalidation: smaller grant and new epoch after planning, unchanged queued page/hash, exact Simon scores'
