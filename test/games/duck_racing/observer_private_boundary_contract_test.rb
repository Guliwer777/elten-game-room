require_relative 'client_helpers'
require_relative '../../support/duck_game_adapter'
require_relative '../../../lib/game_event_presenter'

# Independent acceptance boundary: every private commitment/reveal is a real
# model action. Partial reveals, refresh and a cold observer must not turn
# an unfinished private round into an answer recap.
class DuckObserverPrivateBoundaryContract
  include DuckClientTest

  def run
    [[false, 'Carol'], [false, 'Watcher'], [true, 'Watcher']].each do |group, viewer|
      quiz(group, viewer)
    end
    ball_totals
    report('Duck observer private boundary: pair/group Quiz partial reveal, cold entry, no-answer result, one shared recap and requested-only ball totals')
  end

  def setup_observer(h, viewer)
    @h, @viewer, @replay, @game = h, viewer, h.replay, h.game
    @program = DuckChallengeAudioTest::Program.new
    @client = CLIENT.new(@program, @game, clock: -> { @program.now_ms / 1000.0 },
      session_time: ->(_state) { @h.now_ms },
      presentation_busy: -> { @presenter&.event_presentation_busy? },
      realtime_factory: -> { Realtime.new(@program) },
      progress_factory: ->(**_options, &block) { @progress = Progress.new(&block) })
    @client.bind_screen(session_id: 91, table_id: 41, owner: 'Alice', viewer: viewer, members: -> { @h.players })
    @client.start
    @client.update_table_control(h.session)
    @presenter = GameRoomEventPresenter.new(game: -> { @game }, repository: -> { @h.repository },
      program: -> { @program }, viewer: -> { @viewer }, client: -> { @client }, surface_state: -> { {} },
      clock: -> { @program.now_ms / 1000.0 }, covered: -> { false },
      speech: ->(text) { $spoken_messages << text }, trace: ->(*_args, **_options) {},
      history_changed: ->(*_args) {}, session_changed: -> {})
    @presenter.process_new_events(@replay, session: h.session)
    @client.before_wait(@replay, viewer)
    attach
    $spoken_messages.clear
  end

  def refresh
    @replay = @h.replay
    @presenter.process_new_events(@replay, session: @h.session)
    @client.before_wait(@replay, @viewer)
    10.times do
      @program.now_ms += 1000
      @presenter.event_presentation&.advance
      @client.progress_frame
    end
  end

  def safe_unfinished
    assert_equal(nil, @h.replay.state[:last_resolution], 'Fixture unexpectedly resolved before all private reveals')
    view = @client.local_view
    %i[answers correct_index answer own_answer own own_result].each do |key|
      assert(!view.key?(key), "Observer retained private #{key}")
    end
    assert_equal(false, @surface.presentation[:enabled])
    assert_equal(nil, request, 'Observer generated an input, heartbeat or readiness request')
    assert_equal([], @program.events, 'Private quiz observation played a countdown or answer sound')
    assert($spoken_messages.none? { |text| text.include?('Correct answer:') || text.match?(/\b(?:Alice|Bob|Carol|Dave):/) },
      'Partial private progress disclosed an answer recap')
  end

  def quiz(group, viewer)
    h = DuckGameAdapterTest::Harness.new(kind: 'quiz', count: 4)
    challenge = h.open_round(group: group)
    h.begin_round
    question = ENGINE.start(challenge, resources: h.resources)[:model][:question]
    setup_observer(h, viewer)
    expected = {}
    challenge[:participants].each_with_index do |seat, index|
      trace = GameRoomDuckRacing::ChallengeTrace.new(challenge, seat: seat, resources: h.resources, compact: true)
      if index == challenge[:participants].length - 1
        trace.tick(at: GameRoomDuckRacing::QuizChallenge::DURATION_MS)
        expected[seat] = 'No answer'
      else
        value = index.zero? ? question[:correct_index] : (question[:correct_index] + 1) % 4
        assert(trace.submit({kind: :answer, value: value, press_id: 1}, at: 100 + index * 100))
        expected[seat] = question[:choices].fetch(value)
      end
      h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace.snapshot}, actor: h.players.fetch(seat))
      refresh
      safe_unfinished
    end
    assert(@client.local_view[:answered].values.all?, 'Observer missed accepted completion progress')
    challenge[:participants].each_with_index do |seat, index|
      actor = h.players.fetch(seat)
      protocol = h.replay.state[:round][:private]
      recovery = GameRoomDuckRacing::PrivateRound.recover(protocol, seat: seat, user: actor, vault: h.vault(actor))
      recovery.reveal_pages.each do |page|
        h.accept({'action' => 'reveal', 'challenge' => challenge[:id], 'page' => page}, actor: actor)
        refresh
        safe_unfinished unless h.replay.state[:last_resolution]
      end
      if index.zero? && challenge[:participants].length > 1
        # A separate cold observer must not use an already revealed prefix as
        # authority to display any answer before ordinary final settlement.
        cold = CLIENT.new(@program, @game, clock: -> { @program.now_ms / 1000.0 },
          session_time: ->(_state) { h.now_ms }, realtime_factory: -> { Realtime.new(@program) },
          progress_factory: ->(**_options, &block) { Progress.new(&block) })
        cold.bind_screen(session_id: 91, table_id: 41, owner: 'Alice', viewer: 'ColdWatcher', members: -> { h.players })
        cold.start
        cold.update_table_control(h.session)
        cold.before_wait(h.replay, 'ColdWatcher')
        assert(!cold.local_view.key?(:answers) && !cold.local_view.key?(:correct_index), 'Cold observation exposed a revealed prefix')
        cold.close
      end
    end
    lines = $spoken_messages.join("\n").split("\n")
    expected.each do |seat, answer|
      assert_equal(1, lines.count("#{h.players.fetch(seat)}: #{answer}."), 'Verified final answer/no-answer was missing or repeated')
    end
    assert_equal(1, lines.count("Correct answer: #{question[:choices].fetch(question[:correct_index])}."))
    assert(h.replay.history.none? { |entry| expected.any? { |seat, answer| entry.text == "#{h.players.fetch(seat)}: #{answer}." } },
      'Observer-only answer recap was written into canonical history')
    previous = $spoken_messages.dup
    3.times { refresh }
    assert_equal(previous, $spoken_messages, 'A stable final snapshot replayed answers')
  ensure
    @presenter&.event_presentation&.close
    close
    @presenter = nil
  end

  def ball_totals
    setup_client('numbered_balls', viewer: 'Charlie')
    engine = @replay.state[:round][:engine]
    seat = ENGINE.current_turn(engine)
    assert(ENGINE.submit(engine, seat: seat, action: {kind: :take, value: 2, press_id: 1}, now_ms: 100, resources: resources))
    @replay.state[:revision] += 1
    $spoken_messages.clear
    @client.before_wait(@replay, @viewer)
    view = @client.local_view
    score = view.fetch(:scores).fetch(seat)
    assert_equal(10, view.fetch(:remaining).length, 'Public ball list did not lose two picked values')
    assert_equal([], $spoken_messages, 'Ball total was automatically repeated')
    name = @replay.players.fetch(seat)
    assert(GameRoomDuckRacing::ChallengePresentation.reminder('numbered_balls', view).include?("#{name}: #{score}."),
      'Requested ball totals omitted the accepted public score')
    assert_equal(nil, request)
  ensure
    close
  end
end

DuckObserverPrivateBoundaryContract.new.run
