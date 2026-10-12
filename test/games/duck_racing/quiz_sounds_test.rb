# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
require_relative 'client_helpers'
require_relative '../../../lib/duck_racing/quiz_sounds'
require_relative '../../../lib/game_event_presenter'

# Actual Duck input/trace, commitment/reveal and the shared event presenter.
# Only storage and the audio device use the existing isolated test fixtures.
class DuckQuizSoundsTest
  include DuckClientTest

  FEEDBACK = %w[buzzer2 replay quiz_wrong_answer duck_correct].freeze

  def run
    @results = []
    check('local countdown boundaries and duplicate frames') { timer_boundaries }
    check('new question, late frame, elapsed timeout and closed client') { timer_lifecycle }
    check('answered, committed and spectator attempts remain silent') { timer_privacy }
    check('countdown gain, disabled sounds and background suppression') { timer_policy }
    check('verified right, wrong, missing and observer result sounds') { verified_results }
    check('cancelled quiz and a racer outside the duel') { excluded_results }
    check('result gain and background suppression') { result_policy }
    puts JSON.pretty_generate(checks: @checks, scenarios: @results)
    $stdout.flush
    raise 'Duck Quiz sound regression failed' unless @results.all? { |result| result[:status] == 'PASS' }
    report('Duck Quiz sounds: local deadline and accepted shared answer feedback')
  end

  def check(name)
    yield
    @results << {name: name, status: 'PASS'}
  rescue StandardError => error
    @results << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(6)}
  ensure
    @outputs.to_a.each(&:close)
    @outputs = []
    close
    DuckChallengeAudioTest::Program.settings = {}
  end

  def names(program = @program)
    program.events.map { |event| event[:asset] }.select { |asset| FEEDBACK.include?(asset) }
  end

  def timer_boundaries
    setup_client('quiz')
    [0, 10_000, 14_999].each { |ms| advance(ms) }
    assert_equal([], names)
    advance(15_000)
    assert_equal(['buzzer2'], names)
    [15_000, 15_001, 16_000, 19_999].each { |ms| advance(ms); replace }
    assert_equal(['buzzer2'], names, 'The warning repeated during refresh or another countdown frame')
    advance(20_000)
    assert_equal('submit_trace', request['action'])
    assert_equal(['buzzer2'], names, 'A local timeout disclosed or played the result')
  end

  def timer_lifecycle
    setup_client('quiz')
    advance(15_000)
    replace do |replay|
      replay.state[:round][:challenge][:id] = 2
      replay.state[:race][:challenge][:id] = 2
    end
    advance(29_999)
    assert_equal(['buzzer2'], names)
    advance(30_000)
    assert_equal(%w[buzzer2 buzzer2], names, 'A new question reused its predecessor warning state')
    close
    setup_client('quiz')
    advance(19_999)
    assert_equal(['buzzer2'], names, 'A late frame inside the warning window lost its cue')
    close
    setup_client('quiz')
    advance(20_000)
    advance(25_000)
    assert_equal([], names, 'A frame after expiry played an obsolete warning')
    close
    setup_client('quiz')
    close
    advance(15_000)
    assert_equal([], names, 'A closed client still played a countdown')
  end

  def timer_privacy
    [true, false].each do |correct|
      setup_client('quiz')
      index = @client.instance_variable_get(:@trace).state[:model][:question][:correct_index]
      @surface.push(:answer, value: correct ? index : (index + 1) % 4)
      advance(14_999)
      assert_equal('submit_trace', request['action'])
      [15_000, 19_000, 20_000].each { |ms| advance(ms); replace }
      assert_equal([], names, 'An answered local attempt played a warning or leaked correctness')
      close
    end
    setup_client('quiz')
    replace { |replay| replay.state[:round][:private][:commitments][0] = 'accepted' }
    advance(15_000)
    assert_equal([], names, 'A committed attempt still warned its author')
    close
    setup_client('quiz', viewer: 'Charlie')
    advance(15_000)
    advance(20_000)
    assert_equal([], names, 'The observer received a personal question countdown')
  end

  def output_for(program, covered:)
    (@outputs ||= []) << GameRoomSoundOutput.new(program, audio_game: true, covered: covered)
    @outputs.last
  end

  def timer_policy
    setup_client('quiz')
    @program.gain = 0.27
    advance(15_000)
    assert_equal(0.27, @program.events.last[:volume])
    close
    setup_client('quiz')
    @program.enabled = false
    advance(15_000)
    @program.enabled = true
    advance(16_000)
    assert_equal([], names, 'Re-enabling sounds replayed a consumed warning')
    close
    setup_client('quiz')
    output = output_for(@program, covered: -> { @progress.covered })
    @program.class.settings = {'background_game_sounds' => 'all'}
    @progress.covered = true
    advance(15_000, background: true)
    assert_equal(['buzzer2'], names)
    assert_equal(0.0, @program.events.last[:volume], 'A covered warning bypassed the game audio policy')
    @progress.covered = false
    output.tick
    advance(16_000)
    assert_equal(['buzzer2'], names)
    assert_equal(0.0, @program.sounds.last.volume, 'Returning made a muted one-shot audible')
  end

  def start_question(count: 4, group: true)
    @h = DuckGameAdapterTest::Harness.new(count: count, kind: 'quiz')
    @h.open_round(group: group)
    @h.begin_round
    @h.replay
  end

  def presenter(viewer, program = DuckChallengeAudioTest::Program.new)
    service = GameRoomEventPresenter.new(game: -> { @h.game }, repository: -> { @h.repository },
      program: -> { program }, viewer: -> { viewer }, client: -> { nil }, surface_state: -> { {} },
      clock: -> { program.now_ms / 1000.0 }, covered: -> { false }, speech: ->(_text) {},
      trace: ->(*_args, **_options) {}, history_changed: ->(*_args) {}, session_changed: -> {})
    service.process_new_events(@h.replay, session: @h.session)
    [service, program]
  end

  def emit(outputs, replay = @h.replay)
    outputs.each_value { |service, _program| service.process_new_events(replay, session: @h.session) }
  end

  def submit_answers(outputs, choices)
    challenge = @h.replay.state[:round][:challenge]
    challenge[:participants].each do |seat|
      trace = GameRoomDuckRacing::ChallengeTrace.new(challenge, seat: seat, resources: @h.resources)
      if choices.fetch(seat).nil?
        trace.tick(at: GameRoomDuckRacing::QuizChallenge::DURATION_MS)
      else
        answer = trace.state[:model][:question][:correct_index]
        answer = (answer + 1) % 4 unless choices.fetch(seat)
        assert(trace.submit({kind: :answer, value: answer, press_id: 1}, at: 100 + seat * 50))
      end
      @h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace.snapshot},
        actor: @h.players.fetch(seat))
      emit(outputs)
      outputs.each_value { |_service, program| assert_equal([], names(program), 'A commitment leaked personal answer feedback') }
    end
    @h.accept({'action' => 'advance', 'challenge' => challenge[:id]}, author: @h.owner)
    emit(outputs)
    outputs.each_value { |_service, program| assert_equal([], names(program), 'Entering reveal played answer feedback early') }
    challenge
  end

  def reveal_answers(outputs, challenge)
    challenge[:participants].each do |seat|
      user = @h.players.fetch(seat)
      prepared = GameRoomDuckRacing::PrivateRound.recover(@h.replay.state[:round][:private],
        seat: seat, user: user, vault: @h.vault(user))
      assert(prepared)
      prepared.reveal_pages.each do |page|
        @final_before = @h.replay
        @final_start = @h.events.length
        @h.accept({'action' => 'reveal', 'challenge' => challenge[:id], 'page' => page}, actor: user)
        emit(outputs)
        if @h.replay.state[:round]&.dig(:challenge, :id) == challenge[:id]
          outputs.each_value { |_service, program| assert_equal([], names(program), 'A partial reveal played the result before shared verification') }
        end
      end
    end
    assert_equal(challenge[:id], @h.replay.state[:last_resolution][:id])
  end

  def verified_results
    initial = start_question
    outputs = %w[Alice alice Bob Carol Dave Observer].to_h { |viewer| [viewer, presenter(viewer)] }
    challenge = submit_answers(outputs, {0 => true, 1 => false, 2 => nil, 3 => true})
    reveal_answers(outputs, challenge)
    expected = {'Alice' => ['replay'], 'alice' => ['replay'], 'Bob' => ['quiz_wrong_answer'],
      'Carol' => ['quiz_wrong_answer'], 'Dave' => ['replay'], 'Observer' => []}
    expected.each { |viewer, cues| assert_equal(cues, names(outputs.fetch(viewer).last), "Wrong verified feedback for #{viewer}") }
    3.times { emit(outputs) }
    emit(outputs, initial)
    expected.each { |viewer, cues| assert_equal(cues, names(outputs.fetch(viewer).last), 'Snapshot or old replay repeated feedback') }
    first = @h.events.fetch(@final_start)
    assert(first['id'] != @h.events.last['id'], 'Result fixture did not cross actual payload fragments')
    cue = GameRoomSounds.event_cue(game: @h.game, event: first, before_replay: @final_before,
      after_replay: @h.replay, repository: @h.repository, viewer: 'Alice')
    assert_equal(nil, cue, 'An unfinished event payload played the final result')
  end

  def excluded_results
    start_question(count: 2)
    outputs = {'Alice' => presenter('Alice')}
    id = @h.replay.state[:round][:challenge][:id]
    @h.accept({'action' => 'cancel', 'challenge' => id, 'reason' => 'technical'}, actor: 'Alice')
    emit(outputs)
    assert_equal([], names(outputs['Alice'].last), 'A technical cancellation sounded like a wrong answer')

    start_question(group: false)
    outputs = {'Carol' => presenter('Carol')}
    challenge = submit_answers(outputs, {0 => false, 1 => true})
    reveal_answers(outputs, challenge)
    assert_equal([], names(outputs['Carol'].last), 'A racer outside the duel received another player\'s result')
  end

  def result_policy
    start_question(count: 2)
    outputs = {'Alice' => presenter('Alice'), 'Bob' => presenter('Bob')}
    alice, bob = outputs['Alice'].last, outputs['Bob'].last
    alice.gain, bob.gain = 0.21, 0.31
    covered = true
    output = output_for(bob, covered: -> { covered })
    bob.class.settings = {'background_game_sounds' => 'all'}
    challenge = submit_answers(outputs, {0 => true, 1 => false})
    reveal_answers(outputs, challenge)
    assert_equal(['replay'], names(alice))
    assert_equal(0.21, alice.events.last[:volume], 'A correct result ignored personal game volume')
    assert_equal(['quiz_wrong_answer'], names(bob))
    assert_equal(0.0, bob.events.last[:volume], 'A wrong result bypassed covered-game muting')
    covered = false
    output.tick
    emit(outputs)
    assert_equal(0.0, bob.sounds.last.volume)
    assert_equal(['quiz_wrong_answer'], names(bob), 'Returning replayed the wrong-answer cue')
  end
end

DuckQuizSoundsTest.new.run
