# frozen_string_literal: true

require_relative '../../support/duck_game_adapter'
require_relative 'client_helpers'
require_relative '../../../lib/game_event_presenter'

class DuckAnswerSoundsTest
  include DuckClientTest

  def run
    @results = []
    GameRoomDuckRacing::AnswerSounds::LOCAL_TYPES.each do |kind|
      check("#{kind}: wrong then correct, one personal cue, no refresh repeats") { local_answer(kind) }
      check("#{kind}: wrong/expired attempt is silent") { exhausted(kind) }
    end
    check('Quiz retains hidden local correctness') { excluded_quiz }
    check('gain, disabled sound, covered input and observer') { policy }
    check('new challenge can confirm again') { new_challenge }
    check('sound order does not confirm speculative or partial swaps') { speculative_order }
    check('sound order confirms only the accepted solver, once') { accepted_order }
    check('cancelled sound order gives no confirmation') { cancelled_order }
    puts JSON.pretty_generate(checks: @checks, scenarios: @results)
    raise 'Duck answer sound regression failed' unless @results.all? { |entry| entry[:status] == 'PASS' }
    report('Duck personal correct-answer sounds')
  end

  def check(name)
    yield
    @results << {name: name, status: 'PASS'}
  rescue StandardError => error
    @results << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}", backtrace: error.backtrace.first(5)}
  ensure
    @outputs.to_a.each(&:close)
    @outputs = []
    close
    DuckChallengeAudioTest::Program.settings = {}
  end

  def cues(program = @program)
    program.events.select { |event| event[:asset] == 'duck_correct' }
  end

  def ready(kind)
    setup_client(kind)
    if kind == 'count_ducks'
      4_000.times do
        break if @client.local_view[:preparing]
        advance(@program.now_ms + 10)
      end
      assert(@client.local_view[:preparing], 'Ducks did not reach the answer preparation')
    end
    finish_preparation if ENGINE::SPEED_TYPES.include?(kind)
    @trace = @client.instance_variable_get(:@trace)
    @answer = kind == 'count_ducks' ? @trace.state[:model][:private][:count] : @trace.state[:model][:answer]
  end

  def answer(value)
    @surface.push(:answer, value: value)
    advance(@program.now_ms + 1)
  end

  def local_answer(kind)
    ready(kind)
    assert_equal([], cues)
    answer(@answer == 1 ? 2 : @answer - 1)
    assert_equal([], cues, 'A wrong or merely close answer played the success sound')
    assert(!@trace.finished?, 'Fixture exhausted the attempt before the correct answer')
    answer(@answer)
    assert(@trace.finished?)
    assert_equal(1, cues.length, 'The accepted local answer was not confirmed immediately')
    assert_equal(@program.now_ms, cues.first[:at])
    assert_equal(@program.gain, cues.first[:volume])
    assert_equal('submit_trace', request['action'])
    @surface.push(:answer, value: @answer)
    3.times { advance(@program.now_ms + 50); replace }
    assert_equal(1, cues.length, 'Refresh or a repeated input repeated the confirmation')
    close
    advance(@program.now_ms + 1_000)
    assert_equal(1, cues.length)
  end

  def exhausted(kind)
    ready(kind)
    answer(@answer == 1 ? 2 : @answer - 1)
    advance(@program.now_ms + 180_000)
    assert(@trace.finished?)
    assert_equal('submit_trace', request['action'])
    assert_equal([], cues, 'Timeout/nearest guess was mistaken for a correct answer')
  end

  def excluded_quiz
    setup_client('quiz')
    trace = @client.instance_variable_get(:@trace)
    answer(trace.state[:model][:question][:correct_index])
    assert(trace.finished?)
    assert_equal([], cues, 'Quiz disclosed the answer before shared reveal')
  end

  def policy
    ready('guess_number')
    @program.gain = 0.23
    answer(@answer)
    assert_equal(0.23, cues.first[:volume])
    close
    ready('guess_number')
    @program.enabled = false
    answer(@answer)
    @program.enabled = true
    replace
    advance(1_000)
    assert_equal([], cues, 'Enabling sound replayed an old confirmation')
    close
    ready('guess_number')
    @progress.covered = true
    answer(@answer)
    assert_equal([], cues, 'A covered field consumed an answer')
    @progress.covered = false
    advance(100)
    assert_equal([], cues, 'Returning consumed hidden-field input')
    close
    setup_client('guess_number', viewer: 'Charlie')
    answer(10)
    advance(180_000)
    assert_equal([], cues, 'An observer received personal answer feedback')
  end

  def new_challenge
    ready('guess_number')
    answer(@answer)
    replace do |replay|
      replay.state[:round][:challenge][:id] = 2
      replay.state[:race][:challenge][:id] = 2
    end
    attach
    answer(@client.instance_variable_get(:@trace).state[:model][:answer])
    assert_equal(2, cues.length)
  end

  def sorting_swaps(values)
    (0...8).each do |first|
      next if values[first] == first + 1
      second = values.index(first + 1)
      yield first + 1, second + 1
      values[first], values[second] = values[second], values[first]
    end
  end

  def speculative_order
    setup_client('sound_order')
    finish_preparation(delay_ms: ENGINE::ORDER_PREPARATION_DELAY_MS)
    @surface.push(:preview, value: 1)
    advance(@program.now_ms + 1)
    sorting_swaps(@client.local_view[:own][:arrangement].dup) do |first, second|
      @surface.push(:swap, value: first, other: second)
      advance(@program.now_ms + 1)
      assert_equal([], cues, 'An unaccepted swap claimed completion')
    end
    assert_equal('input', request['action'])
  end

  def presenter(h, viewer)
    program = DuckChallengeAudioTest::Program.new
    service = GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
      program: -> { program }, viewer: -> { viewer }, client: -> { nil }, surface_state: -> { {} },
      clock: -> { program.now_ms / 1000.0 }, covered: -> { false }, speech: ->(_text) {},
      trace: ->(*_args, **_options) {}, history_changed: ->(*_args) {}, session_changed: -> {})
    service.process_new_events(h.replay, session: h.session)
    [service, program]
  end

  def emit(h, outputs, replay = h.replay)
    outputs.each_value { |service, _program| service.process_new_events(replay, session: h.session) }
  end

  def order_round
    h = DuckGameAdapterTest::Harness.new(kind: 'sound_order', count: 3)
    h.open_round(group: false)
    h.begin_round
    h
  end

  def accepted_order
    h = order_round
    initial = h.replay
    outputs = %w[Alice alice Bob Carol Observer].to_h { |viewer| [viewer, presenter(h, viewer)] }
    outputs['Alice'].last.gain = 0.32
    covered = true
    (@outputs ||= []) << GameRoomSoundOutput.new(outputs['alice'].last, audio_game: false, covered: -> { covered })
    DuckChallengeAudioTest::Program.settings = {'background_game_sounds' => 'all'}
    engine = h.replay.state[:round][:engine]
    sorting_swaps(ENGINE.view(engine, seat: 0)[:own][:arrangement].dup) do |first, second|
      before = h.replay
      round = before.state[:round]
      start = h.events.length
      h.accept({'action' => 'input', 'challenge' => round[:challenge][:id],
        'input' => {'kind' => 'swap', 'value' => first, 'other' => second,
          'press_id' => round[:engine][:last_press][0] + 1}}, actor: 'Alice',
        at: [h.now_ms + 10, round[:started_at] + ENGINE::ORDER_PREPARATION_MS].max)
      (start...h.events.length).each do |index|
        emit(h, outputs, h.game.replay(h.session, h.events.take(index), h.repository))
        outputs.each_value { |_service, program| assert_equal([], cues(program), 'A partial payload claimed a solution') }
      end
      emit(h, outputs)
      if h.replay.state[:round]
        outputs.each_value { |_service, program| assert_equal([], cues(program), 'A partial arrangement was confirmed') }
      end
    end
    assert_equal('sound_order', h.replay.state[:last_resolution][:kind])
    assert_equal(1, cues(outputs['Alice'].last).length)
    assert_equal(0.32, cues(outputs['Alice'].last).first[:volume])
    assert_equal(1, cues(outputs['alice'].last).length)
    assert_equal(0.0, cues(outputs['alice'].last).first[:volume], 'Background muting was bypassed')
    %w[Bob Carol Observer].each { |viewer| assert_equal([], cues(outputs[viewer].last)) }
    3.times { emit(h, outputs) }
    emit(h, outputs, initial)
    covered = false
    @outputs.first.tick
    assert_equal(1, cues(outputs['Alice'].last).length)
    assert_equal(0.0, cues(outputs['alice'].last).first[:sound].volume)
    assert_equal([], cues(presenter(h, 'Alice').last), 'Joining a completed challenge replayed confirmation')
  end

  def cancelled_order
    h = order_round
    outputs = {'Alice' => presenter(h, 'Alice')}
    h.accept({'action' => 'cancel', 'challenge' => h.replay.state[:round][:challenge][:id],
      'reason' => 'technical'}, actor: 'Alice')
    emit(h, outputs)
    assert_equal([], cues(outputs['Alice'].last))
  end
end

DuckAnswerSoundsTest.new.run
