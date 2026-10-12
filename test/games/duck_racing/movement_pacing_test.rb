require_relative '../../support/duck_game_adapter'
require_relative 'challenge_audio_helpers'
require_relative '../../../lib/game_event_presenter'

include DuckGameAdapterTest

h = Harness.new
before = h.start
race = before.state[:race]
race[:occupants] = {}
[2, 18].each_with_index do |progress, seat|
  race[:racers][seat][:progress] = progress
  LOGIC::Board.arrive!(race[:occupants], seat, LOGIC::Board.square(progress))
end
race[:racers][0][:hand] << LOGIC::Cards::Copy.new('move-test', 'shortness_of_breath')
race[:traps][22] = {card: LOGIC::Cards::Copy.new('trap-test', 'counter_current'), owner: 0}
seed = (0..10_000).find do |value|
  random = Random.new(value)
  random.rand(8) == 5 && random.rand(2) == 1
end
race[:random] = Random.new(seed)

after = Marshal.load(Marshal.dump(before))
assert(LOGIC::Race.new(after.state[:race]).apply(seat: 0, revision: race[:revision],
  action: {kind: :play, card: 'move-test', target: 1}))
assert_equal(18, after.state[:race][:racers][1][:progress])
event = {'__id' => 999, 'id' => 999, 'actor' => 'Alice'}
after.accepted_events = before.accepted_events + [event]
h.game.send(:append_notices, after.history, after.state[:race][:notices], 999, after.players)
entries = after.history.select { |entry| entry.event_id == 999 }
stages = h.game.event_presentation_stages(event, h.repository, before, after, 'Bob')
assert_equal([1.0, 1.0, 1.0, 0.0], stages.map { |stage| stage[:delay] })
assert_equal(entries, stages.flat_map { |stage| stage[:history] }, 'Canonical history was lost or repeated')
assert_equal(entries.map(&:text), stages.flat_map { |stage| stage[:descriptions] })
assert(stages[0][:descriptions].last == 'Bob moves back 3 squares.')
assert(stages[1][:descriptions].first == 'Bob lands on square 16. Whirlpool.')
assert(stages[1][:descriptions].last == 'Bob moves forward 6 squares.')
assert(stages[2][:descriptions].first == 'Bob lands on square 22. North bank.')
assert(stages[2][:history].any? { |entry| entry.kind == :drew_cards })
assert(stages[2][:history].any? { |entry| entry.kind == :trap })
assert(stages[2][:descriptions].last == 'Bob moves back 3 squares.')
assert(stages[3][:descriptions].first == 'Bob lands on square 19. Natural shelter.')

snapshot = DuckGameAdapterTest.semantic(after.state)
[false, true].each do |covered|
  [false, true].each do |muted|
    program = DuckChallengeAudioTest::Program.new
    program.enabled = !muted
    program.duration_ms = 20_000
    spoken, callbacks = [], []
    client = Object.new
    client.define_singleton_method(:event) { |item, *_args| callbacks << item['id'] }
    presenter = GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
      program: -> { program }, viewer: -> { 'Bob' }, client: -> { client }, surface_state: -> { {} },
      clock: -> { program.now_ms / 1000.0 }, covered: -> { covered },
      speech: ->(text) { spoken << [program.now_ms, text] }, trace: ->(*_args, **_options) {},
      history_changed: ->(*_args) {}, session_changed: -> {})
    # The fixture supplies one already accepted transition; the actual queue,
    # event sounds, history filtering and duplicate-refresh handling run here.
    presenter.define_singleton_method(:event_replays_for) do |_replay, events, session:|
      events.to_h { |item| [item['id'], [before, after]] }
    end
    presenter.process_new_events(before, session: h.session)
    spoken.clear
    presenter.process_new_events(after, session: h.session)
    [0, 1_000, 2_000, 3_000].each_with_index do |time, index|
      program.now_ms = time
      presenter.event_presentation.advance
      assert_equal(stages[index][:descriptions], spoken.select { |at, _text| at == time }.map(&:last))
      next if index == 3
      program.now_ms = time + 999
      previous = spoken.dup
      presenter.process_new_events(after, session: h.session)
      assert_equal(previous, spoken, 'Refresh skipped a displacement pause')
      assert(presenter.event_presentation_busy?)
    end
    assert(!presenter.event_presentation_busy?)
    assert_equal([999], callbacks, 'Staging repeated the client event')
    assert_equal(snapshot, DuckGameAdapterTest.semantic(after.state), 'Pacing mutated accepted state')
    previous = spoken.dup
    presenter.process_new_events(after, session: h.session)
    assert_equal(previous, spoken)
  end
end

# The same splitter covers a continuation after a challenge, preserving both
# existing result pauses and the final challenge-introduction delay.
continued = Marshal.load(Marshal.dump(after))
result = LOGIC::Settlement.fixed(balances: {0 => 18, 1 => 18}, winner: 0, amount: 4)
continued.state[:last_resolution] = {settlement: result}
continued.history = []
h.game.send(:append_notices, continued.history,
  [[:challenge_result, 1, result]] + after.state[:race][:notices], 999, after.players)
parts = h.game.event_presentation_stages(event, h.repository, before, continued, 'Bob')
assert_equal([2.0, 2.0, 1.0, 1.0, 1.0, 0.0], parts.map { |part| part[:delay] })
assert_equal(continued.history, parts.flat_map { |part| part[:history] })

# No extra pause for a clamped move that stays at the start, or a plain
# landing (the preceding roll already supplies its single second).
no_move = Marshal.load(Marshal.dump(before))
no_move.history = []
h.game.send(:append_notices, no_move.history, [[:stayed, 0]], 999, no_move.players)
assert_equal([0.0], h.game.event_presentation_stages(event, h.repository, before, no_move, 'Bob').map { |part| part[:delay] })

puts 'PASS Duck chained movement: three 1s pauses, destination/rewards together, result continuation, fixed clock, muted/covered presentation, deduplication and immutable state'
