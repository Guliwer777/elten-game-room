# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
require_relative 'challenge_audio_helpers'
require_relative '../../../lib/game_event_presenter'

include GameRoomTest::Assertions
logic = GameRoomDuckRacing

%w[copy_number quiz].each do |kind|
  h = DuckGameAdapterTest::Harness.new(kind: kind, count: 3)
  challenge = h.open_round(group: false)
  h.begin_round
  before = h.replay
  if kind == 'copy_number'
    h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id],
      'trace' => h.private_traces.fetch(0)}, actor: 'Alice')
  else
    question = logic::ChallengeEngine.start(challenge, resources: h.resources)[:model][:question]
    challenge[:participants].each do |seat|
      trace = logic::ChallengeTrace.new(challenge, seat: seat, resources: h.resources, compact: true)
      value = seat.zero? ? question[:correct_index] : (question[:correct_index] + 1) % 4
      assert(trace.submit({kind: :answer, value: value, press_id: 1}, at: 100 + seat * 100))
      h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace.snapshot}, actor: h.players.fetch(seat))
    end
    assert_equal(nil, h.replay.state[:last_resolution], 'Unrevealed quiz commitments exposed results')
    challenge[:participants].each do |seat|
      actor = h.players.fetch(seat)
      prepared = logic::PrivateRound.recover(h.replay.state[:round][:private], seat: seat, user: actor, vault: h.vault(actor))
      prepared.reveal_pages.each { |page| h.accept({'action' => 'reveal', 'challenge' => challenge[:id], 'page' => page}, actor: actor) }
    end
  end
  after = h.replay
  state = DuckGameAdapterTest.semantic(after.state)
  history = Marshal.dump(after.history)
  resolution = after.state.fetch(:last_resolution)
  expected = resolution[:results].map do |seat, result|
    value = result[:answer]
    detail = value.nil? ? 'No answer' : kind == 'quiz' ? question[:choices].fetch(value) : value.to_s
    "#{h.players.fetch(seat)}: #{detail}."
  end
  event = h.events.last
  %w[Carol Watcher].each do |viewer|
    stages = h.game.event_presentation_stages(event, h.repository, before, after, viewer)
    descriptions = stages.flat_map { |stage| stage[:descriptions] }.join("\n").split("\n")
    expected.each { |line| assert_equal(1, descriptions.count(line), "#{kind}: final choice missing or repeated for #{viewer}") }
    assert_equal(1, descriptions.count("Correct answer: #{resolution[:answer]}."))
    assert_equal(after.history.select { |entry| entry.event_id == h.repository.event_id(event) },
      stages.flat_map { |stage| stage[:history] }, 'Observation duplicated canonical history')
    # Use the real shared queue too, including its cold-entry and repeated-
    # refresh suppression rather than testing only a result formatting helper.
    program = DuckChallengeAudioTest::Program.new
    spoken = []
    presenter = GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
      program: -> { program }, viewer: -> { viewer }, client: -> { nil }, surface_state: -> { {} },
      clock: -> { program.now_ms / 1000.0 }, covered: -> { false }, speech: ->(text) { spoken << text },
      trace: ->(*_args, **_options) {}, history_changed: ->(*_args) {}, session_changed: -> {})
    presented = Marshal.load(Marshal.dump(after))
    presenter.process_new_events(Marshal.load(Marshal.dump(before)), session: h.session)
    presenter.process_new_events(presented, session: h.session)
    10.times do
      program.now_ms += 1_000
      presenter.process_new_events(presented, session: h.session)
    end
    expected.each { |line| assert_equal(1, spoken.join("\n").split("\n").count(line), "#{kind}: presenter skipped/repeated observer result") }
    prior = spoken.dup
    presenter.process_new_events(presented, session: h.session)
    assert_equal(prior, spoken, 'Refresh repeated the observed result')
  end
  %w[Alice Bob].each do |viewer|
    descriptions = h.game.event_presentation_stages(event, h.repository, before, after, viewer)
      .flat_map { |stage| stage[:descriptions] }.join("\n").split("\n")
    assert((descriptions & expected).empty?, "#{kind}: participant got an extra answer recap")
  end
  assert_equal(state, DuckGameAdapterTest.semantic(after.state), 'Result observation changed replay state')
  assert_equal(history, Marshal.dump(after.history), 'Result observation edited shared history')
end

puts 'PASS Duck observer final numbers/quiz choices, participant concise output, shared queue and refresh deduplication'
