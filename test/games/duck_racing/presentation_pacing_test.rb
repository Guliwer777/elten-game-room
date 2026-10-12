require_relative '../../support/duck_game_adapter'
require_relative 'challenge_audio_helpers'
require_relative '../../../lib/game_event_presenter'

include GameRoomTest::Assertions

def paced_presenter(h, program, spoken, client_events, covered: false)
  client = Object.new
  client.define_singleton_method(:event) { |event, *_args| client_events << h.repository.event_id(event) }
  GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
    program: -> { program }, viewer: -> { 'Alice' }, client: -> { client }, surface_state: -> { {} },
    clock: -> { program.now_ms / 1000.0 }, covered: -> { covered },
    speech: ->(text) { spoken << [program.now_ms, text] }, trace: ->(*_args, **_options) {},
    history_changed: ->(*_args) {}, session_changed: -> {})
end

[false, true].each do |covered|
  [false, true].each do |muted|
    h = DuckGameAdapterTest::Harness.new
    seed = (1..100).find do |value|
      race = GameRoomDuckRacing::Race.start(player_count: 2, laps: 3, enabled_challenges: ['guess_number'], seed: value)
      GameRoomDuckRacing::Race.new(race).apply(seat: 0, revision: 0, action: {kind: :roll})
      race[:phase] == :turn
    end
    h.start(seed: seed)
    program = DuckChallengeAudioTest::Program.new
    program.enabled = !muted
    program.duration_ms = 20_000 # A long recording does not extend a fixed pause.
    spoken, client_events = [], []
    presenter = paced_presenter(h, program, spoken, client_events, covered: covered)
    presenter.process_new_events(h.replay, session: h.session)
    spoken.clear
    previous_ids = h.events.map { |event| h.repository.event_id(event) }
    h.accept({'action' => 'race', 'input' => {'kind' => 'roll'}}, actor: 'Alice')
    after = h.replay
    presenter.process_new_events(after, session: h.session)
    assert_equal(1, spoken.length)
    assert(spoken.first.last.start_with?('Alice rolls '), 'First stage is not the roll')
    assert(presenter.event_presentation_busy?)
    [1, 250, 999].each do |time|
      program.now_ms = time
      presenter.process_new_events(after, session: h.session)
      assert_equal(1, spoken.length, 'Destination was spoken before one second')
    end
    program.now_ms = 1_000
    presenter.event_presentation.advance
    assert(spoken.any? { |time, text| time == 1_000 && text.include?('lands on square') }, 'Destination missing after one second')
    assert(spoken.none? { |_time, text| text == "It is Bob's turn." }, 'Turn jumped ahead of the two-second pause')
    program.now_ms = 2_999
    presenter.event_presentation.advance
    assert(presenter.event_presentation_busy?)
    program.now_ms = 3_000
    presenter.event_presentation.advance
    assert(!presenter.event_presentation_busy?)
    assert_equal([3_000, "It is Bob's turn."], spoken.last)
    assert_equal(client_events.uniq, client_events, 'Splitting one event duplicated its client callback')
    assert_equal(h.events.map { |event| h.repository.event_id(event) } - previous_ids, client_events)
    assert_equal(muted ? [] : ['roll'], program.events.map { |entry| entry[:asset] }.select { |asset| asset == 'roll' })
    assert_equal(DuckGameAdapterTest.semantic(after.state), DuckGameAdapterTest.semantic(h.replay.state), 'Presentation changed accepted game state')
    snapshot = spoken.dup
    presenter.process_new_events(after, session: h.session)
    assert_equal(snapshot, spoken, 'Refresh repeated a delayed announcement')
  end
end

h = program = nil
[false, true].each do |covered|
  [false, true].each do |muted|
    h = DuckGameAdapterTest::Harness.new
    h.open_round
    h.begin_round
    program = DuckChallengeAudioTest::Program.new
    program.enabled = !muted
    program.duration_ms = 20_000
    spoken, client_events = [], []
    presenter = paced_presenter(h, program, spoken, client_events, covered: covered)
    presenter.process_new_events(h.replay, session: h.session)
    spoken.clear
    h.finish_private
    presenter.process_new_events(h.replay, session: h.session)
    assert(spoken.any? { |_time, text| text == 'Alice wins.' }, 'Challenge winner was not announced')
    assert(spoken.none? { |_time, text| text.include?('feather') }, 'Feathers were announced with the winner')
    assert(presenter.event_presentation_busy?, 'No pause after a challenge result')
    assert(spoken.none? { |_time, text| text == 'It is your turn.' })
    program.now_ms = 1_999
    presenter.process_new_events(h.replay, session: h.session)
    assert(presenter.event_presentation_busy?)
    assert(spoken.none? { |_time, text| text.include?('feather') }, 'A refresh skipped the winner-to-feathers pause')
    program.now_ms = 2_000
    presenter.event_presentation.advance
    assert(spoken.any? { |time, text| time == 2_000 && text.include?('feather') }, 'Feathers missing after two seconds')
    assert(presenter.event_presentation_busy?)
    program.now_ms = 3_999
    presenter.event_presentation.advance
    assert(presenter.event_presentation_busy?)
    program.now_ms = 4_000
    presenter.event_presentation.advance
    assert(!presenter.event_presentation_busy?)
    assert_equal([4_000, 'It is your turn.'], spoken.last)
    spoken_before_refresh = spoken.dup
    presenter.process_new_events(h.replay, session: h.session)
    assert_equal(spoken_before_refresh, spoken, 'Winner or feathers repeated on refresh')
    assert_equal(client_events.uniq, client_events, 'Result stages duplicated the client callback')
  end
end

# Only a won challenge adds the winner-to-feathers pause. Keep penalties,
# grants and draws intact; canonical history must never be duplicated.
[
  ['simon', {0 => {score: 16}, 1 => {score: 10}}, 20, false, [2.0, 2.0, 0.0]],
  ['simon', {0 => {score: 16}, 1 => {score: 10}}, 0, true, [2.0, 2.0, 0.0]],
  ['simon', {0 => {score: 16}, 1 => {score: 10}}, 0, false, [2.0, 0.0]],
  ['blackjack', {0 => {score: 21}, 1 => {score: 24}}, 20, false, [2.0, 2.0, 0.0]],
  ['blackjack', {0 => {score: 22}, 1 => {score: 25}}, 20, false, [2.0, 0.0]],
  ['blackjack', {0 => {score: 21}, 1 => {score: 21}}, 20, false, [2.0, 0.0]],
  ['quiz', {0 => {correct: true}, 1 => {correct: false}}, 20, false, [2.0, 0.0]]
].each do |kind, scores, balance, frozen, delays|
  result = GameRoomDuckRacing::ChallengeEngine.settlement(kind,
    balances: {0 => 20, 1 => balance}, results: scores)
  after = h.replay.dup
  after.state = after.state.merge(last_resolution: {kind: kind, settlement: result})
  after.history = []
  event = h.events.last
  notices = [[:challenge_result, 1, result]]
  notices << [:frozen, 1, 2] if frozen
  h.game.send(:append_notices, after.history, notices, h.repository.event_id(event), after.players)
  snapshot = DuckGameAdapterTest.semantic(after.state)
  stages = h.game.event_presentation_stages(event, h.repository, nil, after, 'Alice')
  assert_equal(delays, stages.map { |stage| stage[:delay] }, kind)
  assert_equal(after.history, stages.flat_map { |stage| stage[:history] }, 'History split lost or duplicated entries')
  assert_equal(after.history.map(&:text).join("\n"), stages.flat_map { |stage| stage[:descriptions] }.join("\n"),
    'Splitting speech changed the result')
  assert_equal(snapshot, DuckGameAdapterTest.semantic(after.state))
  if frozen
    assert(stages.first[:history].none? { |entry| entry.kind == :frozen })
    assert(stages[1][:history].any? { |entry| entry.kind == :frozen })
  end
end

# Cold entry never replays an old roll or delays an already pending turn.
cold = paced_presenter(h, program, [], [])
cold.process_new_events(h.replay, session: h.session)
assert(!cold.event_presentation_busy?)
puts 'PASS Duck pacing: roll 1s, next turn 2s, winner 2s before feathers, result 2s, muted/long audio, foreground/background, duplicate refresh, atomic state, cold entry'
