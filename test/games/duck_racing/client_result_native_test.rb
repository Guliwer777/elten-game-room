# frozen_string_literal: true

require_relative '../../support/duck_challenge_native'
require_relative '../../support/duck_game_adapter'
require_relative 'client_helpers'
require_relative '../../../lib/game_event_presenter'
require_relative '../../../lib/game_history_view'
require_relative '../../../lib/table_history_exporter'

# Native speech dispatch, real Client/Engine and verified action_for/replay.
# Local input uses the existing fixture surface; this is not an acoustic or
# physical keyboard test. Final results pass through the shared presenter.
class DuckClientResultNativeTest
  include DuckClientTest

  def run
    @scenarios = []
    @case_filter = Regexp.new(ENV.fetch('DUCK_NATIVE_CASE')) if ENV.key?('DUCK_NATIVE_CASE')
    scenario('dice duel manual roll') { dice_result }
    scenario('dice duel deadline roll') { dice_result(automatic: true) }
    scenario('risky dice last, over-limit roll') { risky_result }
    scenario('blackjack accepted card and stand') { blackjack_result }
    scenario('numbered balls new turn') { sequential_turn('numbered_balls') }
    scenario('sound memory new turn after mismatch') { sequential_turn('sound_memory') }
    scenario('sound memory matched pair and new turn') { sequential_turn('sound_memory', matched: true) }
    %w[numbered_balls sound_memory].each do |kind|
      scenario("#{kind} turn decision identity and manual T") { sequential_decision(kind) }
    end
    %w[rock_paper_scissors dice_duel blackjack risky_dice copy_number arithmetic race_question count_ducks guess_number quiz].each do |kind|
      scenario("#{kind} verified final result and repeat refresh") { final_result(kind) }
    end
    raise 'No native result scenarios matched DUCK_NATIVE_CASE' if @scenarios.empty?
    puts JSON.pretty_generate(scenarios: @scenarios)
    failures = @scenarios.reject { |row| row[:status] == 'PASS' }
    raise "Duck result speech failed: #{failures.map { |row| row[:name] }.join('; ')}" unless failures.empty?

    report('Duck native result speech, sequential turn cues, verified final results and deduplication')
  end

  def scenario(name)
    return if @case_filter && !@case_filter.match?(name)

    evidence = yield
    @scenarios << {name: name, status: 'PASS', evidence: evidence}
  rescue StandardError => error
    @scenarios << {name: name, status: 'FAIL', error: "#{error.class}: #{error.message}",
      backtrace: error.backtrace.first(5), speech: speech_calls}
  ensure
    close
    @client = nil
    $lastactivecontrols = $activecontrols = []
  end

  def speech_calls
    SpeechOutput.calls.map(&:dup)
  end

  def utterances
    speech_calls.map(&:first)
  end

  def no_refresh_speech
    expected = speech_calls
    3.times do |index|
      replace { |replay| replay.state[:round][:last_seen][1] += index + 1 }
      advance(@program.now_ms + 1)
    end
    assert_equal(expected, speech_calls, 'Unrelated state refresh repeated speech')
  end

  def dice_result(automatic: false)
    setup_public_client('dice_duel')
    if automatic
      round = @h.replay.state[:round]
      advance(10_000)
      assert_equal([], utterances, 'The local timer announced an unaccepted automatic roll')
      assert_equal([], @program.events, 'The local timer played an unaccepted automatic roll')
      @h.accept({'action' => 'advance', 'challenge' => round[:challenge][:id]},
        author: @h.owner, at: round[:started_at] + 10_000)
      refresh_public
    else
      accept_public_input(:roll, at: 100)
    end
    own = @client.local_view.fetch(:own)
    assert(own[:done])
    assert_equal(automatic ? :automatic_roll : :rolled, own[:status])
    assert_equal([latest_notice(:challenge_roll)], utterances, 'The accepted roll was replaced by a waiting message')
    inspection = "Roll: #{own.fetch(:rolls).last.join(', ')}. Total: #{own.fetch(:total)}."
    assert(@surface.presentation[:header].include?(inspection), 'The completed result cannot be inspected')
    assert_equal(nil, request, 'A completed public roll left a local request queued')
    assert_equal(['roll'], @program.events.map { |event| event[:asset] })
    no_public_refresh_output
    {speech: speech_calls, own_total: own[:total], automatic: automatic}
  end

  def risky_result
    setup_public_client('risky_dice')
    rolls = []
    20.times do |index|
      give_public_turn('risky_dice')
      SpeechOutput.reset
      accept_public_input(:roll, at: 100 + index * 100)
      own = @client.local_view&.fetch(:own)
      total = own ? own[:total] : @replay.state[:last_resolution][:results].fetch(0)[:score]
      expected = latest_notice(:challenge_roll)
      assert_equal(1, utterances.count(expected), 'The final roll was omitted or repeated before the settlement')
      if own
        inspection = "Roll: #{own.fetch(:rolls).last.join(', ')}. Total: #{total}."
        assert(@surface.presentation[:header].include?(inspection))
      end
      rolls << {total: total, status: own && own[:status], speech: speech_calls}
      break if !own || own[:done]
    end
    assert(rolls.last[:total] > 25, 'Fixture must exercise the final over-limit roll')
    assert_equal(nil, request)
    accepted_rolls = @replay.history.count { |entry| entry.kind == :challenge_roll }
    assert_equal(accepted_rolls, @program.events.count { |event| event[:asset] == 'roll' })
    no_public_refresh_output
    rolls
  end

  def blackjack_result
    setup_public_client('blackjack')
    before = Marshal.dump(@client.local_view[:own])
    accept_public_input(:hit, at: 100)
    own = @client.local_view.fetch(:own)
    assert(before != Marshal.dump(own), 'The accepted draw did not change the hand')
    assert_equal([latest_notice(:challenge_draw)], utterances)
    assert_equal(['draw'], @program.events.map { |event| event[:asset] })
    no_public_refresh_output
    unless own[:done]
      assert_equal(0, ENGINE.current_turn(@replay.state[:round][:engine]), 'Drawing below 21 handed the turn to the peer')
      assert(@surface.presentation[:enabled], 'Drawing disabled the current player before standing')
      SpeechOutput.reset
      accept_public_input(:stand, at: 200)
      assert_equal(1, utterances.count(latest_notice(:challenge_stand)))
      assert_equal([latest_notice(:challenge_stand), latest_notice(:challenge_hand)], utterances,
        'The next hand must follow the previous player standing, exactly once')
      round = @replay.state[:round]
      assert_equal(1, ENGINE.current_turn(round[:engine]))
      assert(!@surface.presentation[:enabled], 'Standing left the finished player enabled')
      @h.accept({'action' => 'input', 'challenge' => round[:challenge][:id],
        'input' => {'kind' => 'stand', 'press_id' => round[:engine][:last_press].fetch(1) + 1}}, actor: 'Bob')
      refresh_public
      assert_equal(own[:total], @replay.state[:last_resolution][:results].fetch(0)[:score])
      assert_equal(2, @program.events.count { |event| event[:asset] == 'draw' },
        'Expected one drawn card and the next player\'s initial hand')
      no_public_refresh_output
    end
    {speech: speech_calls, own_hand_before_standing: own}
  end

  # Public dice/card input still passes through the real Client and ordinary
  # action_for/replay. Only this fixture's external storage/sound and keyboard
  # surface are replaced; it never supplies a roll, card or finished result.
  def setup_public_client(kind)
    @h = DuckGameAdapterTest::Harness.new(kind: kind)
    @h.open_round
    @h.begin_round
    @replay, @viewer = @h.replay, 'Alice'
    @program = DuckChallengeAudioTest::Program.new
    @game = @h.game
    @client = CLIENT.new(@program, @game, clock: -> { @program.now_ms / 1000.0 },
      session_time: ->(_state) { @h.now_ms },
      progress_factory: ->(**_options, &block) { @progress = Progress.new(&block) })
    @client.bind_screen(session_id: 91, table_id: 41, owner: 'Alice', viewer: @viewer,
      members: -> { @h.players })
    @client.start
    @client.update_table_control(@h.session)
    @client.before_wait(@replay, @viewer)
    attach
    @presenter = presenter_for(@h, @program)
    @presenter.process_new_events(@replay, session: @h.session)
    SpeechOutput.reset
    @program.events.clear
    assert_equal(nil, @client.instance_variable_get(:@trace), 'A public turn created a private trace')
  end

  def presenter_for(harness, program)
    GameRoomEventPresenter.new(game: -> { harness.game }, repository: -> { harness.repository },
      program: -> { program }, viewer: -> { 'Alice' }, client: -> { nil }, surface_state: -> { {} },
      clock: -> { program.now_ms / 1000.0 }, covered: -> { false },
      speech: ->(text) { speak(text, stop: false, break_sequence: false) },
      trace: ->(*_args) {}, history_changed: ->(*_args) {}, session_changed: -> {})
  end

  def refresh_public
    @replay = @h.replay
    @client.update_table_control(@h.session)
    @client.before_wait(@replay, @viewer)
    @client.progress_frame(background: false)
    @presenter.process_new_events(@replay, session: @h.session)
  end

  def accept_public_input(kind, at:)
    own = Marshal.dump(@client.local_view[:own])
    speech, sounds = speech_calls, @program.events.dup
    @surface.push(kind)
    advance(at)
    assert_equal(own, Marshal.dump(@client.local_view[:own]), 'A queued public action exposed a speculative result')
    assert_equal(speech, speech_calls, 'A queued public action announced a speculative result')
    assert_equal(sounds, @program.events, 'A queued public action played a speculative result')
    assert_equal('input', request&.fetch('action'))
    assert_equal(kind.to_s, request.dig('input', 'kind'))
    round = @h.replay.state[:round]
    @h.accept(request, actor: 'Alice', at: round[:started_at] + at)
    refresh_public
    assert_equal(nil, request, 'Accepted public input was not acknowledged')
  end

  def latest_notice(kind)
    @replay.history.reverse.find { |entry| entry.kind == kind }.text
  end

  def give_public_turn(kind)
    8.times do
      round = @h.replay.state[:round]
      engine = round.fetch(:engine)
      seat = GameRoomDuckRacing::ChallengeEngine.current_turn(engine)
      return if seat.zero?

      @h.accept({'action' => 'input', 'challenge' => round[:challenge][:id],
        'input' => {'kind' => kind == 'blackjack' ? 'stand' : 'roll',
          'press_id' => engine[:last_press].fetch(seat) + 1}}, actor: @h.players.fetch(seat))
      refresh_public
    end
    raise 'Public peer input did not return the turn'
  end

  def no_public_refresh_output
    speech, sounds = speech_calls, @program.events.dup
    3.times { refresh_public }
    assert_equal(speech, speech_calls, 'An unchanged public refresh repeated speech')
    assert_equal(sounds, @program.events, 'An unchanged public refresh repeated a sound')
  end

  def engine_turn(engine)
    model = engine[:model]
    engine[:kind] == 'numbered_balls' ? model[:participants][model[:turn_index]] : model[:public][:turn]
  end

  def apply_turn(engine, seat, matched: false)
    if engine[:kind] == 'numbered_balls'
      assert(ENGINE.submit(engine, seat: seat, action: {kind: :take, value: 1, press_id: 1}, now_ms: 100, resources: resources))
      return []
    end
    tones = engine[:model][:private][:pairs]
    index = (1...tones.length).find { |other| (tones[other] == tones.first) == matched }
    positions = [1, index == 9 ? 0 : index + 1]
    positions.each_with_index do |position, press|
      assert(ENGINE.submit(engine, seat: seat, action: {kind: :reveal, value: position, press_id: press + 1},
        now_ms: 100 + press, resources: resources))
    end
    positions
  end

  def sequential_turn(kind, matched: false)
    initial = make_replay(kind)
    previous_turn = engine_turn(initial.state[:round][:engine])
    viewer = previous_turn.zero? ? 'Bob' : 'Alice'
    setup_client(kind, viewer: viewer)
    game = GameRoomGames::DuckRacing.new(resources: resources)
    assert_equal(nil, game.required_decision_key(@replay, viewer), 'A waiting player was marked as deciding')
    SpeechOutput.reset
    positions = nil
    replace { |replay| positions = apply_turn(replay.state[:round][:engine], previous_turn, matched: matched) }
    advance(200)
    assert_equal([], utterances, 'The local client duplicated or overtook the shared turn announcement')
    if matched
      assert(utterances.none? { |line| line.include?('Pair:') }, 'A snapshot recapped a complete pair')
      assert(@surface.presentation[:header].include?("Matched positions: #{positions.join(', ')}."))
    end
    key = game.required_decision_key(@replay, viewer)
    assert_equal([1, @replay.players.index(viewer), kind == 'numbered_balls' ? 100 : 101], key)
    assert_equal("#{viewer}'s turn.", game.turn_text(@replay), 'Manual T did not identify the active player')
    no_refresh_speech
    {speech: speech_calls, decision_key: key, manual_turn: game.turn_text(@replay)}
  end

  def sequential_decision(kind)
    replay = make_replay(kind)
    game = GameRoomGames::DuckRacing.new(resources: resources)
    engine = replay.state[:round][:engine]
    seat = engine_turn(engine)
    actor = replay.players.fetch(seat)
    key = game.required_decision_key(replay, actor)
    assert_equal([1, seat, 0], key)
    assert_equal(nil, game.required_decision_key(replay, 'Charlie'))
    assert_equal(nil, game.required_decision_key(replay, 'Observer'))
    assert_equal("#{actor}'s turn.", game.turn_text(replay))
    snapshot = Marshal.dump(replay)
    3.times { assert_equal(key, game.required_decision_key(replay, actor)) }
    assert_equal(snapshot, Marshal.dump(replay), 'Reading turn presentation mutated a replay')

    # Two elapsed turn deadlines can return control to the same person in a
    # single accepted advance. It is nevertheless a new required decision.
    cycle_ms = kind == 'numbered_balls' ? 120_000 : 30_000
    assert(ENGINE.expire(engine, now_ms: cycle_ms))
    assert_equal(seat, engine_turn(engine))
    new_key = game.required_decision_key(replay, actor)
    assert_equal([1, seat, cycle_ms], new_key)
    assert(new_key != key)
    assert_equal("#{actor}'s turn.", game.turn_text(replay))
    assert(ENGINE.expire(engine, now_ms: kind == 'numbered_balls' ? 900_000 : 300_000))
    assert(ENGINE.finished?(engine))
    replay.players.each { |viewer| assert_equal(nil, game.required_decision_key(replay, viewer)) }
    {first_key: key, next_cycle_key: new_key, after_completion: nil}
  end

  def final_result(kind)
    harness = DuckGameAdapterTest::Harness.new(kind: kind)
    challenge = harness.open_round
    harness.begin_round
    program = DuckChallengeAudioTest::Program.new
    presenter = presenter_for(harness, program)
    presenter.process_new_events(harness.replay, session: harness.session)
    SpeechOutput.reset
    if %w[rock_paper_scissors guess_number].include?(kind)
      harness.finish_private
    elsif ENGINE::FIRST_ANSWER.include?(kind)
      finish_first_answer(harness, challenge)
    elsif kind == 'quiz'
      finish_quiz(harness, challenge)
    else
      finish_public(harness, challenge)
    end
    result = harness.replay
    assert(result.state[:last_resolution], 'No verified result')
    presenter.process_new_events(result, session: harness.session)
    1_000.times do
      break unless presenter.event_presentation_busy?
      program.now_ms += 100
      presenter.event_presentation.advance
    end
    assert(!presenter.event_presentation_busy?, 'Result presentation did not finish')
    details = result.history.select { |entry| entry.kind == :challenge_details }.map(&:text)
    settlement = result.history.find { |entry| entry.kind == :challenge_result }.text
    resolution = result.state[:last_resolution]
    expected_details = case kind
    when 'rock_paper_scissors'
      ["Alice: Rock.\nBob: Scissors."]
    when 'guess_number'
      lines = ["Correct answer: #{resolution[:answer]}."]
      harness.players.each_with_index do |player, seat|
        attempt = resolution[:results].fetch(seat)
        assert(attempt[:attempts].positive?, 'Presentation must not discard the attempt data')
        lines << "#{player}: #{attempt.fetch(:best).fetch(:value)}."
      end
      [lines.join("\n")]
    when 'arithmetic', 'race_question', 'count_ducks', 'quiz'
      ["Correct answer: #{resolution[:answer]}."]
    else
      []
    end
    assert_equal(expected_details, details, 'The final summary still repeats answers, totals or attempt counts')
    details.each { |text| assert_equal(1, utterances.count(text), 'Final details were not delivered exactly once') }
    settlement.lines(chomp: true).each do |line|
      assert_equal(1, utterances.flat_map { |text| text.lines(chomp: true) }.count(line),
        'Winner/feather transfer was not delivered exactly once')
    end
    resolved = resolution[:settlement]
    expected_lines = (resolved.outcome == :quiz ? 0 : 1) + resolved.transfers.length + resolved.burned.length + resolved.grants.length
    assert_equal([expected_lines, 1].max, settlement.split("\n", -1).length, 'Each winner, transfer, penalty and grant must have its own line')
    resolved.balances.each do |seat, feathers|
      assert_equal(feathers, result.state[:race][:racers].fetch(seat)[:feathers],
        'Shorter presentation changed the settled feathers')
    end
    result.history.select { |entry| %i[challenge_roll challenge_draw challenge_stand].include?(entry.kind) }.each do |entry|
      assert_equal(1, utterances.count(entry.text), 'A played roll, draw or stand was omitted or repeated')
    end
    assert(speech_calls.all? { |_text, _method, interrupt| interrupt == false })
    calls = speech_calls
    3.times { presenter.process_new_events(result, session: harness.session) }
    assert_equal(calls, speech_calls, 'Repeated final snapshot repeated a result')
    native_history_roundtrip(details + [settlement])
    {speech: calls, verified_results: result.state[:last_resolution][:results], native_history: 'LF internally, CRLF through the native text API; no blank lines'}
  end

  def native_history_roundtrip(items)
    DuckChallengeNativeDriver.new
    view = GameRoomHistory::View.new(header: 'History')
    assert(view.is_a?(EltenAPI::Controls::EditBox), 'History is not using the native text control')
    view.replace_entries(items, follow_tail: false)
    canonical = items.join("\n")
    exported = canonical.gsub("\n", "\r\n")
    assert_equal(items, view.items)
    assert_equal(exported, view.text, 'Native history lost or duplicated a result line during LF/CRLF conversion')
    assert_equal(canonical.length, view.text_len, 'History cursor offsets counted CRLF as two characters')
    assert(!view.text.match?(/\r\n\r\n|\A\r?\n|\r?\n\z/), 'Native history introduced a blank paragraph')
    last_index = items.length - 1
    view.entry_index = last_index
    assert_equal(items.first(last_index).sum { |item| item.length + 1 }, view.index,
      'A single or multiline result shifted the final history entry incorrectly')
    assert_equal(last_index, view.entry_index)
    original_selection = [view.index, view.check]
    3.times { view.replace_entries(items.map { |item| item.gsub("\n", "\r\n") }, follow_tail: false) }
    assert_equal(exported, view.text, 'Equivalent CRLF refresh changed native history')
    assert_equal(original_selection, [view.index, view.check], 'Equivalent line-ending refresh moved the history cursor')
    SpeechOutput.reset
    view.focus
    assert_equal(["History... Text: \n#{items.last}"], utterances,
      'Focusing a multiline history entry duplicated its text or lost the native field role')
    saved = GameRoomTableHistoryExporter.new.send(:content_for, items)
    assert_equal(exported + "\r\n", saved, 'Plain-text history export inserted extra paragraphs or mixed line endings')
  end

  def finish_first_answer(harness, challenge)
    trace = GameRoomDuckRacing::ChallengeTrace.new(challenge, seat: 0, resources: harness.resources)
    at = 100
    if challenge[:kind] == 'count_ducks'
      playback = ENGINE.stimulus(trace.state, seat: 0)
      at = playback[:events].map { |event| event[:offset_ms] + event[:duration_ms] }.max
      assert(trace.submit({kind: :playback_finished, playback_id: playback[:id]}, at: at))
      answer = trace.state[:model][:private][:count]
    else
      answer = trace.state[:model][:answer]
    end
    assert(trace.submit({kind: :answer, value: answer, press_id: 1}, at: at + 100))
    harness.accept({'action' => 'submit_trace', 'challenge' => challenge[:id],
      'trace' => trace.snapshot}, actor: 'Alice')
  end

  def finish_public(harness, challenge)
    40.times do
      round = harness.replay.state[:round]
      return unless round

      engine = round[:engine]
      seat = ENGINE.current_turn(engine)
      player = engine[:model][:players].fetch(seat)
      input = case challenge[:kind]
      when 'blackjack' then player[:total] < 17 ? 'hit' : 'stand'
      when 'risky_dice' then player[:rolls].length < 2 ? 'roll' : 'save'
      else 'roll'
      end
      harness.accept({'action' => 'input', 'challenge' => challenge[:id],
        'input' => {'kind' => input, 'press_id' => engine[:last_press].fetch(seat) + 1}},
        actor: harness.players.fetch(seat))
    end
    raise 'Public challenge fixture did not finish'
  end

  def finish_quiz(harness, challenge)
    harness.players.each_with_index do |actor, seat|
      trace = GameRoomDuckRacing::ChallengeTrace.new(challenge, seat: seat, resources: harness.resources)
      correct = trace.state[:model][:question][:correct_index]
      assert(trace.submit({kind: :answer, value: seat.zero? ? correct : (correct + 1) % 4, press_id: 1}, at: 100))
      harness.accept({'action' => 'submit_trace', 'challenge' => challenge[:id], 'trace' => trace.snapshot}, actor: actor)
    end
    harness.accept({'action' => 'advance', 'challenge' => challenge[:id]}, author: harness.owner)
    harness.players.each_with_index do |actor, seat|
      prepared = GameRoomDuckRacing::PrivateRound.recover(harness.replay.state[:round][:private],
        seat: seat, user: actor, vault: harness.vault(actor))
      prepared.reveal_pages.each do |page|
        harness.accept({'action' => 'reveal', 'challenge' => challenge[:id], 'page' => page}, actor: actor)
      end
    end
  end
end

DuckClientResultNativeTest.new.run
