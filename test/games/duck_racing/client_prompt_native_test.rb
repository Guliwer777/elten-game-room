# frozen_string_literal: true

require_relative '../../support/duck_challenge_native'
require_relative '../../support/duck_game_adapter'
require_relative 'client_helpers'
require_relative '../../../lib/game_screen'

# Real GameScreen input/layout, native Form/ListBox/EditBox, the Duck client
# and ordinary action_for/replay. The fixture replaces only the external
# sound/storage boundary and feeds a finite native keyboard stream.
class DuckClientPromptNativeTest
  include DuckClientTest

  KINDS = (GameRoomDuckRacing::Challenges::BY_ID.keys - GameRoomDuckRacing::ChallengeEngine::REALTIME).freeze
  QUESTION_KINDS = %w[quiz copy_number arithmetic race_question].freeze
  AUDIO_KINDS = GameRoomDuckRacing::AudioChallenges::TYPES.values.freeze
  AUTOPLAY_KINDS = %w[count_ducks rhythm simon hit_duck].freeze
  LOCAL_PRACTICE = GameRoomDuckRacing::ChallengeEngine::LOCAL_SCORES
  INDEPENDENT = GameRoomDuckRacing::ChallengeEngine::INDEPENDENT

  class Driver < DuckChallengeNativeDriver
    attr_accessor :program

    def snapshot(*arguments, **options)
      @program.now_ms += 20 if @program
      super
    end

    def on_wait(&block)
      raise 'Previous native wait was not consumed' if @on_wait
      @on_wait = block
    end

    def tick(form)
      super
      return unless @on_wait && form.instance_variable_get(:@wait)

      block, @on_wait = @on_wait, nil
      block.call(form)
    end
  end

  class Program < DuckChallengeAudioTest::Program
    def initialize
      super
      @data = {}
      @durations[GameRoomDuckRacing::ChallengeAudio::QUACK_ASSET] = 400
    end

    def read_json(path, default:)
      Marshal.load(Marshal.dump(@data.fetch(path, default)))
    end

    def update_json(path, default:)
      yield(@data[path] ||= Marshal.load(Marshal.dump(default)))
    end
  end

  def run
    @driver = Driver.new
    @results = []
    @case_filter = Regexp.new(ENV.fetch('DUCK_NATIVE_CASE')) if ENV.key?('DUCK_NATIVE_CASE')
    $game_room_test_user = 'Alice'
    [:race, :preparing].product([:game, :chat]).each do |from, focus|
      scenario("quiz full lifecycle from #{from}, focus #{focus}") { quiz_transition(from, focus) }
    end
    KINDS.each do |kind|
      # Independent attempts have no shared preparing phase in protocol 2.
      # Test their local practice entry and an already-open challenge instead.
      entries = INDEPENDENT.include?(kind) ? [:race] : [:race, :preparing]
      entries.product([:game, :chat]).each do |from, role|
        scenario("#{kind} from #{from}, focus #{role}") { challenge_transition(kind, from, role) }
      end
      scenario("#{kind}, cold entry") { cold_challenge_entry(kind) }
      scenario("#{kind}, observer does not receive action instructions") { observer_entry(kind) }
      scenario("#{kind}, accepted native input does not repeat the introduction") { native_answer(kind) }
    end
    AUTOPLAY_KINDS.each do |kind|
      scenario("#{kind}, stimulus starts without automatic speech") { autoplay_stimulus(kind) }
    end
    scenario('RPS native arrows, submitted choice and verified final result') { rps_navigation }
    scenario('Dice duel native roll and verified final result') { dice_result }
    raise 'No native prompt scenarios matched DUCK_NATIVE_CASE' if @results.empty?
    puts JSON.pretty_generate({checks: @checks, scenarios: @results})
    $stdout.flush
    failures = @results.reject { |result| result[:status] == 'PASS' }
    raise "Duck native prompt regressions: #{failures.map { |result| result[:name] }.join('; ')}" unless failures.empty?
    report('Duck native prompt: real screen transitions, speech queue, focus, draft and repeat prevention')
  end

  def scenario(name)
    return if @case_filter && !@case_filter.match?(name)

    yield
    @results << {name: name, status: 'PASS'}
  rescue StandardError => error
    @results << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}",
      backtrace: error.backtrace.first(5), calls: SpeechOutput.calls.map(&:dup), queue: SpeechOutput.queue.dup}
  ensure
    @client&.close
    @screen&.instance_variable_get(:@layout)&.form&.clear_game_room_background_help
    @screen = @client = @form = @surface = nil
    $lastactivecontrols = $activecontrols = []
  end

  def setup_screen(kind, from: :race, viewer: 'Alice')
    @viewer = viewer
    $game_room_test_user = viewer
    @h = DuckGameAdapterTest::Harness.new(kind: kind)
    # Deal two Super challenges naturally. This permits a second challenge
    # without inserting synthetic events, changing cards or resetting a race.
    settings = @h.game.options_from_json(@h.session['options'])
    seed = (1..50_000).find do |candidate|
      race = GameRoomDuckRacing::Race.start(player_count: 2, laps: settings['laps'],
        enabled_challenges: settings['challenges'], seed: candidate)
      race[:racers][0][:hand].count { |card| card.type == 'super_challenge' } >= 2
    end
    assert(seed, 'No natural double-challenge fixture deal')
    @h.start(seed: seed)
    @h.open_round if [:preparing, :playing].include?(from)
    @h.begin_round if from == :playing
    @program = Program.new
    @session_origin = from == :playing ? @h.replay.state[:round][:started_at] : @h.now_ms
    @driver.program = @program
    build_client = @h.game.method(:build_client)
    # Network records must not advance the local audio clock a second time.
    fixture_time = ->(_state) { @session_origin + @program.now_ms }
    @h.game.define_singleton_method(:build_client) do |program, **services|
      build_client.call(program, **services).tap do |client|
        client.instance_variable_set(:@clock, -> { program.now_ms / 1000.0 })
        client.instance_variable_set(:@session_time, fixture_time)
      end
    end
    @screen = GameScreen.new(program: @program, repository: @h.repository, game: @h.game,
      session: @h.session, table: {'__id' => 41}, table_owner: 'Alice',
      room_snapshot_provider: -> { raise 'Unexpected networking in a presentation test' },
      synchronizer: nil)
    program_clock = -> { @program.now_ms / 1000.0 }
    @screen.define_singleton_method(:monotonic_time, &program_clock)
    assert(@screen.send(:start_game_client))
    @client = @screen.instance_variable_get(:@game_client)
    SpeechOutput.reset if from == :playing
    render(silent: false)
  end

  def render(silent: true)
    replay = @h.replay
    @client.update_table_control(@h.session)
    @client.before_wait(replay, @viewer)
    @client.after_events(replay, @viewer, context: @screen.send(:action_context))
    @screen.instance_variable_set(:@suppress_surface_focus, silent)
    observed = nil
    @driver.on_wait do |form|
      layout = @screen.instance_variable_get(:@layout)
      assert(form.equal?(layout.form), 'The real native form was replaced by a stub')
      observed = {calls: SpeechOutput.calls.map(&:dup), queue: SpeechOutput.queue.dup,
        location: layout.focus_location.dup, index: form.index}
      layout.back_button.trigger(:press)
    end
    result = @screen.send(:wait_for_action, replay, @h.repository.events_revision(@h.events))
    assert_equal(:back, result, 'The bounded native wait did not exit through its actual button handler')
    assert(observed, 'The native wait callback did not run')
    @layout = @screen.instance_variable_get(:@layout)
    @form, @surface = @layout.form, @layout.surface
    $lastactivecontrols = [@form]
    @screen.send(:remember_layout_position, @layout)
    observed
  end

  def focus(role)
    12.times do
      break if @layout.focus_location.first == role
      @driver.frame(@form, @driver.tap(0x09))
    end
    assert_equal(role, @layout.focus_location.first, 'Native Tab did not reach the intended room field')
    if role == :chat
      @layout.chat.set_text('Keep this chat draft with its selection.')
      @layout.chat.restore_selection(index: 5, check: 14)
    end
    @screen.send(:remember_layout_position, @layout)
  end

  def prompt
    view = @client.local_view
    GameRoomDuckRacing::ChallengePresentation.prompt(view[:type], view)
  end

  def prompt_calls(value)
    SpeechOutput.calls.select { |call| call.first.include?(value) }
  end

  def assert_one_prompt(value, observed)
    assert_equal(1, prompt_calls(value).length, 'The question was omitted or spoken twice during a single transition')
    expected = value
    assert_equal([expected, 0, false], prompt_calls(value).first, 'The selected question row was not spoken once without interruption')
    assert(observed[:queue].include?(expected), 'Ordinary native focus cut the freshly queued question')
  end

  def begin_challenge(from)
    if from == :race
      @h.open_round
      observed = render
      return observed if INDEPENDENT.include?(@h.replay.state[:round][:challenge][:kind])
      assert_equal(nil, @client.instance_variable_get(:@trace), 'Preparation already exposed a private local attempt')
      if GameRoomDuckRacing::ChallengeEngine::PRACTICE_TYPES.include?(@h.replay.state[:round][:challenge][:kind])
        assert(@client.local_view[:practice], 'Preparation did not expose its unscored preview')
        assert_equal([], @program.events, 'Preparation started the scored stimulus')
        SpeechOutput.reset # The assertions below concern the playing transition.
      else
        assert_equal(nil, @client.local_view)
      end
    end
    @h.begin_round
    @session_origin = @h.replay.state[:round][:started_at] - @program.now_ms
    render
  end

  def heartbeat
    id = @h.replay.state[:round][:challenge][:id]
    @h.accept({'action' => 'alive', 'challenge' => id}, actor: 'Bob',
      at: @h.now_ms + GameRoomDuckRacing::Session::PULSE_MS)
    render
  end

  def quiz_transition(from, role)
    setup_screen('quiz', from: from)
    focus(role)
    chat, draft, index, check = @layout.chat, @layout.chat.text.dup, @layout.chat.index, @layout.chat.check
    SpeechOutput.reset
    observed = begin_challenge(from)
    value = prompt
    assert_one_prompt(value, observed)
    assert_equal(role, @layout.focus_location.first, 'A question stole focus from another field')
    assert(@layout.chat.equal?(chat), 'A question rebuilt the chat control')
    assert_equal([draft, index, check], [chat.text, chat.index, chat.check], 'A question changed the draft or cursor')
    assert_instance_of_native_quiz
    spoken = SpeechOutput.calls.dup
    heartbeat
    3.times { render }
    assert_equal(spoken, SpeechOutput.calls, 'A ready/alive refresh repeated the question')
    assert_equal([draft, index, check], [chat.text, chat.index, chat.check])

    # A direct digit while chat is selected must not become a quiz answer.
    if role == :chat
      @driver.frame(@form, @driver.tap(0x31))
      @client.tick
      assert(@client.context_data.dig('duck_action', 'action') != 'submit_trace', 'Typing in chat submitted an answer')
    end
    assert_manual_tab_reads_prompt(value)
    SpeechOutput.reset
    question = @client.local_view[:question]
    correct = question[:choices].index('Answer')
    assert(correct, 'The fixture correct answer is missing')
    @driver.frame(@form, @driver.tap(0x31 + correct))
    @client.tick
    action = @client.context_data['duck_action']
    assert_equal('submit_trace', action && action['action'], 'A real native digit did not finish the local quiz')
    assert_equal([], prompt_calls(value), 'Submitting an answer repeated the question')
    @h.accept(action, actor: 'Alice')
    render
    heartbeat
    assert_equal([], prompt_calls(value), 'A committed answer/heartbeat repeated the question')

    id = @h.replay.state[:round][:challenge][:id]
    @h.accept({'action' => 'cancel', 'challenge' => id, 'reason' => 'technical'}, actor: 'Bob')
    render
    focus(role)
    SpeechOutput.reset
    open_next_challenge
    render
    @h.begin_round
    second = render
    assert(@h.replay.state[:round][:challenge][:id] != id, 'The second trial reused the old challenge')
    assert_equal(value, prompt, 'The one-question fixture unexpectedly changed its prompt')
    assert_one_prompt(value, second)
    assert_equal(role, @layout.focus_location.first)
  end

  def assert_instance_of_native_quiz
    assert(@surface.is_a?(GameSurfaces::DuckChallengeSurface))
    assert(@surface.fields.first.is_a?(EltenAPI::Controls::ListBox))
    assert_equal(5, @surface.fields.first.options.length)
    assert_equal(prompt, @surface.fields.first.options.first)
  end

  def assert_manual_tab_reads_prompt(value)
    # Both paths matter: a quiet transition on the game field must clear the
    # one-shot flag, while a transition on chat must not set it in the first
    # place. A later deliberate Tab must still read the actual game field.
    focus(:chat) if @layout.focus_location.first == :game
    SpeechOutput.reset
    focus(:game)
    calls = prompt_calls(value)
    assert_equal(1, calls.length, 'The first manual Tab back to the quiz did not read its question exactly once')
    assert_equal([1, true], calls.first.drop(1), 'A deliberate native focus did not use its ordinary announcement')
    assert(SpeechOutput.queue.any? { |text| text.include?(value) }, 'The deliberately focused question was not left in the speech queue')
  end

  def open_next_challenge
    30.times do
      replay = @h.replay
      return if replay.state[:round]
      race = replay.state[:race]
      if race[:turn].zero? && !race[:card_played] &&
          race[:racers][0][:frozen_turns].zero? && race[:racers][0][:skip_turns].zero?
        @h.open_round
        return
      end
      racer = race[:racers].fetch(race[:turn])
      skip = racer[:frozen_turns].positive? || racer[:skip_turns].positive?
      @h.accept({'action' => 'race', 'input' => {'kind' => skip ? 'skip' : 'roll'}},
        actor: skip ? @h.host_actor : replay.current_player,
        author: skip ? @h.owner : replay.current_player)
    end
    raise 'The ordinary race did not reach its next challenge'
  end

  def challenge_transition(kind, from, role)
    setup_screen(kind, from: from)
    focus(role)
    chat = @layout.chat
    original = [chat.text.dup, chat.index, chat.check]
    SpeechOutput.reset
    observed = begin_challenge(from)
    initial = assert_initial_challenge(kind, observed, role: role)
    3.times { render }
    silent_entry = kind == 'count_ducks' || kind == 'sound_memory'
    assert_equal(silent_entry ? 0 : 1, initial_calls(kind).length,
      'A duplicate replay repeated the initial instruction')
    assert(@layout.chat.equal?(chat))
    assert_equal(role, @layout.focus_location.first)
    assert_equal(original, [chat.text, chat.index, chat.check])
    manual_challenge_focus(kind)
    assert(initial.length.positive?) unless silent_entry
  end

  def cold_challenge_entry(kind)
    # A genuinely new GameScreen and client open an already-running challenge.
    # There is no previous layout or focus to preserve, and the ordinary native
    # Form#wait (not a quiet refresh) performs the first focus.
    observed = setup_screen(kind, from: :playing)
    assert_initial_challenge(kind, observed, role: :game, cold: true)
    assert_equal([:game, 0], @layout.focus_location)
    manual_challenge_focus(kind)
  end

  def initial_token(kind)
    return 'You are watching.' unless @viewer == 'Alice'
    return @surface.presentation[:instruction] if @client.local_view&.[](:practice)
    QUESTION_KINDS.include?(kind) ? prompt : GameRoomDuckRacing::ChallengePresentation.description(kind)[1]
  end

  def initial_calls(kind)
    token = initial_token(kind)
    # History carries the title; automatic field speech carries the prompt.
    # Walking through history is not another automatic game-field prompt.
    SpeechOutput.calls.select { |call| call.first.include?(token) && !call.first.start_with?('Game history') }
  end

  def assert_initial_challenge(kind, observed, role:, observer: false, cold: false)
    if kind == 'sound_memory'
      # Readiness already explains the controls. The shared event announces
      # the first player, not another local automatic instruction. A cold
      # native focus still reads the current field normally.
      calls = initial_calls(kind)
      assert_equal(cold ? 1 : 0, calls.length)
      assert_equal([1, true], calls.first.drop(1)) if cold
      return cold ? calls.first.first : ''
    end
    if kind == 'count_ducks' && !observer
      assert_equal([], SpeechOutput.calls, "#{kind}: automatic entry speaks over the listening task")
      return ''
    end
    calls = initial_calls(kind)
    assert_equal(1, calls.length, "#{kind}: missing or repeated initial challenge announcement")
    assert_equal([0, false], calls.first.drop(1), "#{kind}: ordinary focus interrupted the queued instruction")
    text = calls.first.first
    assert(observed[:queue].include?(text), "#{kind}: the initial announcement was removed from the speech queue")
    name, instruction, mode = GameRoomDuckRacing::ChallengePresentation.description(kind)
    if observer
      assert(text.include?('You are watching.'), "#{kind}: observer status was omitted")
      if instruction.empty?
        assert_equal('You are watching.', text, "#{kind}: the observer received extra instructions")
      else
        assert(!text.include?(instruction), "#{kind}: the observer was told to play")
      end
    elsif @client.local_view[:practice]
      assert(LOCAL_PRACTICE.include?(kind))
      assert_equal(nil, @client.instance_variable_get(:@trace), 'Practice started a scored attempt')
      assert(text.include?(@surface.presentation[:instruction]), 'The local start instruction is missing')
      assert(@surface.presentation[:enabled], 'Local practice cannot be started')
    elsif kind == 'quiz'
      assert_equal(prompt, text, 'Quiz entry should read its selected question row, not an unselected answer')
    elsif !QUESTION_KINDS.include?(kind)
      assert(text.include?(instruction), "#{kind}: the entry announcement does not explain the required input")
      if mode == :list && role == :game
        first = @surface.presentation[:options].first
        assert(text.include?(first), "#{kind}: the focused list's initial option was not read")
      end
      if kind == 'blackjack'
        details = GameRoomDuckRacing::ChallengePresentation.inspection_details(kind, @client.local_view,
          @client.local_view.fetch(:own), true)
        assert(!text.include?(details), 'The local introduction repeats blackjack cards from the accepted history')
        assert(@surface.fields.first.label.include?(details), 'Blackjack cards and total cannot be inspected')
      end
    end
    if AUDIO_KINDS.include?(kind)
      assert(!text.match?(/\bListen\.\s|\bRepeat\.\s|\b\d+ sounds?\./), 'A repeated playback status leaked into the initial instruction')
    end
    text
  end

  def manual_challenge_focus(kind)
    focus(:chat) if @layout.focus_location.first == :game
    SpeechOutput.reset
    focus(:game)
    token = kind == 'quiz' ? prompt : initial_token(kind)
    calls = SpeechOutput.calls.select { |call| call.first.include?(token) && !call.first.start_with?('Game history') }
    assert_equal(1, calls.length, "#{kind}: manual Tab did not read the actual field once")
    assert_equal([1, true], calls.first.drop(1), "#{kind}: manual focus was incorrectly suppressed")
    assert(SpeechOutput.queue.any? { |text| text.include?(token) })
  end

  def observer_entry(kind)
    setup_screen(kind, viewer: 'Eve')
    focus(:chat)
    SpeechOutput.reset
    observed = begin_challenge(:race)
    assert_initial_challenge(kind, observed, role: :chat, observer: true)
    assert_equal(:chat, @layout.focus_location.first)
    assert(!@surface.presentation[:enabled], 'An observer received an enabled game action')
    3.times { render }
    assert_equal(kind == 'sound_memory' ? 0 : 1, initial_calls(kind).length)
    manual_challenge_focus(kind)
    instruction = GameRoomDuckRacing::ChallengePresentation.description(kind)[1]
    unless instruction.empty? || kind == 'quiz'
      assert(!initial_calls(kind).last.first.include?(instruction), 'Manual observer focus instructs the viewer to act')
    end
    if kind == 'quiz'
      assert_equal(prompt, @surface.fields.first.options.first, 'An observer cannot inspect the shared quiz question')
    else
      assert(initial_calls(kind).last.first.include?('You are watching.'), 'Manual focus omitted the observer status')
    end
    @driver.frame(@form, @driver.tap(0x0D))
    @client.tick
    assert_equal(nil, @client.context_data['duck_action'], 'An observer submitted an action')
  end

  def key(code, **options)
    @driver.frame(@form, @driver.tap(code, **options))
    @client.tick
  end

  def frame
    @driver.frame(@form)
    @client.tick
  end

  def wait_for_phase(phase)
    2_000.times do
      return if @client.local_view.dig(:own, :phase) == phase
      frame
    end
    raise "Native playback did not reach #{phase}: #{@client.local_view.inspect}"
  end

  def enter_text(value)
    @driver.frame(@form, @driver.tap(value.to_s.upcase.getbyte(0)), characters: value.to_s)
    @client.tick
    key(0x0D) unless @client.context_data.dig('duck_action', 'action') == 'submit_trace'
  end

  def make_sequential_turn_local(kind)
    30.times do
      engine = @h.replay.state[:round][:engine]
      turn = GameRoomDuckRacing::ChallengeEngine.current_turn(engine)
      return if turn.zero?

      input = case kind
      when 'numbered_balls' then {kind: 'take', value: 1}
      when 'dice_duel', 'risky_dice' then {kind: 'roll'}
      when 'blackjack' then {kind: 'stand'}
      when 'sound_memory'
        visible = GameRoomDuckRacing::ChallengeEngine.view(engine, seat: turn).fetch(:public)
        shown = visible[:revealed].map { |entry| entry[:position] }
        choice = ((1..9).to_a + [0] - visible[:removed] - shown).first
        {kind: 'reveal', value: choice}
      else raise "No ordinary peer input for #{kind}"
      end
      input['press_id'] = engine[:last_press].fetch(turn) + 1
      @h.accept({'action' => 'input', 'challenge' => @h.replay.state[:round][:challenge][:id],
        'input' => input}, actor: @h.players.fetch(turn))
      render
    end
    raise 'The ordinary sequential peer action did not return the turn'
  end

  def native_answer(kind)
    setup_screen(kind, from: :playing)
    start_local_practice if LOCAL_PRACTICE.include?(kind)
    make_sequential_turn_local(kind) if GameRoomDuckRacing::ChallengeEngine::SEQUENTIAL.include?(kind)
    wait_for_phase(kind == 'rhythm' ? :ready : :responding) if AUTOPLAY_KINDS.include?(kind)
    400.times do
      break unless @client.local_view[:preparing]
      frame
    end
    assert(!@client.local_view[:preparing], 'The preparation cue never enabled native input')
    SpeechOutput.reset
    trace = @client.instance_variable_get(:@trace)
    previous_press = trace&.state&.dig(:last_press, 0)
    model = trace&.state&.fetch(:model)
    case kind
    when 'rock_paper_scissors', 'dice_duel', 'blackjack', 'risky_dice' then key(0x0D)
    when 'guess_number', 'copy_number', 'arithmetic', 'race_question' then enter_text(model.fetch(:answer))
    when 'numbered_balls' then key(0x31)
    when 'quiz' then key(0x31 + @client.local_view[:question][:choices].index('Answer'))
    when 'count_ducks' then enter_text(model[:private][:count])
    when 'rhythm' then key(0x0D)
    when 'simon' then key(0x30 + model[:private][:sequence].first)
    when 'hit_duck' then key(0x30 + model[:private][:targets].first)
    when 'sound_order'
      key(0x31, modifiers: [0x10])
      key(0x32, modifiers: [0x10])
    when 'sound_memory'
      available = (1..9).to_a + [0] - @client.local_view[:public][:removed]
      key(0x30 + available.first)
    else raise "No native input fixture for #{kind}"
    end
    if trace
      assert(trace.state[:last_press].fetch(0) > previous_press,
        "#{kind}: native input was not accepted: #{ {presentation: @surface.presentation, view: @client.local_view,
          local_time: @program.now_ms, last_press: trace.state[:last_press], actions: trace.instance_variable_get(:@actions),
          pending: @surface.instance_variable_get(:@pending), focus: @form.index}.inspect}")
    else
      action = @client.context_data['duck_action']
      assert_equal('input', action && action['action'], "#{kind}: the native sequential control did not queue an input")
      @h.accept(action, actor: 'Alice', at: @h.now_ms + @program.now_ms)
      render
      assert_equal(nil, @client.context_data['duck_action'], "#{kind}: accepted input remained queued")
    end
    assert_equal([], initial_calls(kind), "#{kind}: answering repeated its introduction")
    spoken = SpeechOutput.calls.map(&:dup)
    3.times { render }
    assert_equal(spoken, SpeechOutput.calls, "#{kind}: unchanged answer refresh repeated speech")
  end

  def autoplay_stimulus(kind)
    setup_screen(kind, from: :playing)
    if LOCAL_PRACTICE.include?(kind)
      assert(@client.local_view[:practice], 'Local attempt skipped practice')
      assert_equal([], @program.events, 'A stimulus played before local confirmation')
      start_local_practice
      SpeechOutput.reset
    end
    assert_equal([], SpeechOutput.calls, 'Cold native focus covered the automatic stimulus')
    trace = @client.instance_variable_get(:@trace)
    stimulus = GameRoomDuckRacing::ChallengeEngine.stimulus(trace.state, seat: 0)
    assert(stimulus, 'The native audio attempt has no stimulus')
    expected_sounds = stimulus.fetch(:events).length
    wait_for_phase(kind == 'rhythm' ? :ready : :responding)
    cue_assets = [GameRoomDuckRacing::ChallengeAudio::TONE_ASSET, GameRoomDuckRacing::ChallengeAudio::QUACK_ASSET,
      *GameRoomDuckRacing::ChallengeAudio::RHYTHM_ASSETS.values]
    actual = @program.events.select { |event| cue_assets.include?(event[:asset]) }
    assert_equal(expected_sounds, actual.length, 'A native playback cue was skipped or repeated')
    assert(actual.each_cons(2).all? { |left, right| left[:at] < right[:at] }, 'The cue order was not preserved')
    expected_speech = case kind
    when 'rhythm' then ['Press Enter to begin.']
    when 'count_ducks'
      digits = trace.state[:model][:private][:count].to_s.length
      ["Answer: #{digits} #{digits == 1 ? 'digit' : 'digits'}."]
    else []
    end
    assert_equal(expected_speech, SpeechOutput.calls.map(&:first), 'Playback progression added intrusive speech')
    if kind == 'rhythm'
      assert(!actual.last[:sound].playing?, 'The ready instruction interrupted the final rhythm tone')
    end
    spoken = SpeechOutput.calls.map(&:dup)
    3.times { render }
    assert_equal(spoken, SpeechOutput.calls, 'An unchanged playback phase repeated its instruction')
  end

  def start_local_practice
    assert_equal(nil, @client.instance_variable_get(:@trace))
    key(0x0D)
    render
    assert(@client.instance_variable_get(:@trace), 'Enter did not start the local attempt')
    assert_equal({}, @h.replay.state[:round][:ready], 'Local start wrote shared readiness')
    assert(@client.context_data.dig('duck_action', 'action') != 'ready', 'Local start queued a shared ready action')
  end

  def finish_private_with_peer(kind, input)
    challenge = @h.replay.state[:round][:challenge]
    @h.accept(@client.context_data.fetch('duck_action'), actor: 'Alice')
    peer = GameRoomDuckRacing::ChallengeTrace.new(challenge, seat: 1, resources: @h.resources, compact: true)
    assert(peer.submit(input.merge(press_id: 1), at: 250), 'The peer fixture action was rejected')
    @h.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => peer.snapshot}, actor: 'Bob')
    assert_equal(:revealing, @h.replay.state[:round][:private][:phase], 'The final commitment did not open reveal')
    challenge[:participants].each do |seat|
      user = @h.players.fetch(seat)
      prepared = GameRoomDuckRacing::PrivateRound.recover(@h.replay.state[:round][:private],
        seat: seat, user: user, vault: @h.vault(user))
      assert(prepared, 'A genuine committed input could not be recovered')
      prepared.reveal_pages.each do |page|
        @h.accept({'action' => 'reveal', 'challenge' => challenge[:id], 'page' => page}, actor: user)
      end
    end
    assert_equal(challenge[:id], @h.replay.state[:last_resolution][:id])
    assert_equal(kind, @h.replay.state[:last_resolution][:kind])
    SpeechOutput.reset
    @screen.send(:process_new_events, @h.replay)
    spoken = SpeechOutput.calls.map(&:first)
    @screen.send(:process_new_events, @h.replay)
    assert_equal(spoken, SpeechOutput.calls.map(&:first), 'The shared result presenter repeated an accepted result')
    spoken
  end

  def rps_navigation
    setup_screen('rock_paper_scissors', from: :playing)
    @screen.send(:process_new_events, @h.replay)
    SpeechOutput.reset
    field = @surface.fields.first
    key(0x28)
    assert_equal(1, field.index)
    assert_equal(['Paper'], SpeechOutput.calls.map { |call| call.first.strip }, 'The arrow did not read just its newly selected choice')
    frame
    key(0x28)
    assert_equal(2, field.index)
    assert_equal('Scissors', SpeechOutput.calls.last.first.strip)
    key(0x26)
    assert_equal(1, field.index)
    assert_equal('Paper', SpeechOutput.calls.last.first.strip)
    SpeechOutput.reset
    key(0x0D)
    assert_equal('submit_trace', @client.context_data.dig('duck_action', 'action'))
    assert_equal('paper', @client.local_view.dig(:own, :choice))
    spoken = SpeechOutput.calls.map(&:first)
    assert_equal([], initial_calls('rock_paper_scissors'), 'Submitting a choice repeated the full instructions')
    3.times { render }
    assert_equal(spoken, SpeechOutput.calls.map(&:first), 'Refreshing a chosen RPS answer repeated its acknowledgement')
    result = finish_private_with_peer('rock_paper_scissors', {kind: :choose, value: 'rock'})
    assert(result.any? { |text| text.include?('Alice: Paper.') && text.include?('Bob: Rock.') },
      'The shared final presentation omitted the verified RPS choices')
    assert(result.any? { |text| text.include?('Alice wins.') }, 'The verified RPS winner was not read')
  end

  def dice_result
    setup_screen('dice_duel', from: :playing)
    @screen.send(:process_new_events, @h.replay)
    SpeechOutput.reset
    @program.events.clear
    key(0x0D)
    action = @client.context_data.fetch('duck_action')
    assert_equal('input', action['action'])
    assert_equal('roll', action.dig('input', 'kind'))
    assert_equal([], @client.local_view.fetch(:own)[:rolls], 'A queued roll was presented before it was accepted')
    assert_equal([], SpeechOutput.calls)
    assert_equal([], @program.events)
    @h.accept(action, actor: 'Alice')
    @screen.send(:process_new_events, @h.replay)
    render
    own = @client.local_view.fetch(:own)
    result = "Roll: #{Array(own[:rolls].last).join(', ')}. Total: #{own[:total]}."
    assert(own[:done])
    assert(@surface.presentation[:header].include?(result), 'The completed dice roll cannot be inspected')
    accepted = @h.replay.history.reverse.find { |entry| entry.kind == :challenge_roll }.text
    assert_equal([accepted], SpeechOutput.calls.map(&:first), 'The shared presenter did not announce the accepted roll exactly once')
    assert_equal(['roll'], @program.events.map { |event| event[:asset] })
    assert_equal(nil, @client.context_data['duck_action'], 'The accepted public roll remained queued')
    assert_equal([], initial_calls('dice_duel'), 'Rolling repeated the full dice instructions')
    spoken = SpeechOutput.calls.map(&:first)
    3.times do
      @screen.send(:process_new_events, @h.replay)
      render
    end
    assert_equal(spoken, SpeechOutput.calls.map(&:first), 'Refreshing a completed roll repeated its result')
    assert_equal(['roll'], @program.events.map { |event| event[:asset] }, 'Refreshing repeated the roll sound')
    round = @h.replay.state[:round]
    peer_seat = GameRoomDuckRacing::ChallengeEngine.current_turn(round[:engine])
    assert_equal(1, peer_seat)
    @h.accept({'action' => 'input', 'challenge' => round[:challenge][:id],
      'input' => {'kind' => 'roll', 'press_id' => 1}}, actor: @h.players.fetch(peer_seat))
    SpeechOutput.reset
    @screen.send(:process_new_events, @h.replay)
    final = SpeechOutput.calls.map(&:first)
    assert(@h.replay.history.none? { |entry| entry.kind == :challenge_details },
      'The final dice result repeated scores already announced with the rolls')
    peer_roll = @h.replay.history.reverse.find { |entry| entry.kind == :challenge_roll }.text
    settlement = @h.replay.history.find { |entry| entry.kind == :challenge_result }.text
    outcome, feathers = settlement.split("\n", 2)
    assert_equal([peer_roll, outcome], final, 'The last roll and winner must each be read once')
    @program.now_ms += 1_999
    @screen.send(:process_new_events, @h.replay)
    assert_equal(final, SpeechOutput.calls.map(&:first), 'Feathers were read before the result pause')
    @program.now_ms += 1
    @screen.send(:process_new_events, @h.replay)
    final += [feathers]
    assert_equal(final, SpeechOutput.calls.map(&:first), 'Feathers were not read once after two seconds')
    3.times { @screen.send(:process_new_events, @h.replay) }
    assert_equal(final, SpeechOutput.calls.map(&:first), 'The shared final presentation repeated a result')
    assert_equal(2, @program.events.count { |event| event[:asset] == 'roll' })
  end
end

DuckClientPromptNativeTest.new.run
