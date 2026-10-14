require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'
require_relative '../../support/localization'

class DuckShotFeedbackTest
  include DuckClientTest

  def run
    @driver = DuckChallengeNativeDriver.new
    @real_controls = true
    (1..9).each { |position| shot(position) }
    all_five_shots
    cancellation
    translations
    report('Duck shots: native digits, nine pans, five quality bands, pauses, final trace and cancellation')
  end

  def setup_shots
    setup_client('hit_duck')
    @messages = []
    messages, program = @messages, @program
    @client.define_singleton_method(:announce) { |text| messages << [program.now_ms, text]; true }
    @program.durations[GameRoomDuckRacing::ChallengeAudio::SHOT_ASSET] = 994
    @surface = GameSurfaces.build(@client.surface_spec(@replay, @viewer))
    @form = @driver.form(@surface)
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
    step
  end

  def step(code = nil, delta: 20)
    @program.now_ms += delta
    @driver.frame(@form, code ? @driver.tap(code) : [])
    @client.tick
  end

  def trace; @client.instance_variable_get(:@trace); end
  def quacks; @program.events.select { |event| event[:asset] == 'duck_quack' }; end
  def shots; @program.events.select { |event| event[:asset] == 'duck_shot' }; end

  def finish_feedback
    until_ms = shots.last[:at] + 994 + GameRoomDuckRacing::ChallengeAudio::SHOT_FEEDBACK_PAUSE_MS
    step(delta: until_ms - @program.now_ms) if @program.now_ms < until_ms
    # If a UI frame was delayed, the quiet pause begins when feedback is
    # actually spoken, not at an imagined earlier completion time.
    step(delta: 2_000)
  end

  def shot(position)
    setup_shots
    assert_equal(:responding, @client.local_view.dig(:own, :phase))
    target = trace.state[:model][:private][:targets].first
    expected = [100 - 25 * (position - target).abs, 0].max
    step(0x30 + position)
    assert_equal(1, shots.length)
    assert_equal((position - 5) / 4.0, shots.last[:pan], 'Shot used the target position instead of the pressed digit')
    assert_equal(expected, @client.local_view.dig(:own, :last_target_score))
    assert_equal(nil, GameRoomDuckRacing::ChallengeEngine.view(trace.state, seat: 1).dig(:own, :last_target_score))
    assert_equal([], @messages, 'Quality interrupted the shot')
    assert(!quacks.first[:sound].playing?, 'Old quack kept playing over the shot')
    step(0x31)
    assert_equal(1, shots.length, 'A key during feedback fired another shot')
    step(delta: shots.last[:at] + 974 - @program.now_ms)
    assert_equal([], @messages)
    step
    assert_equal([[shots.last[:at] + 994, GameRoomDuckRacing::ChallengePresentation.shot_quality(expected)]], @messages)
    assert_equal(1, quacks.length)
    step(delta: 1_980)
    assert_equal(1, quacks.length)
    step
    assert_equal(2, quacks.length)
    assert_equal(:responding, @client.local_view.dig(:own, :phase))
    assert_equal(quacks.last[:at] + 3_000, @client.local_view.dig(:own, :deadline_ms), 'Feedback consumed the next response window')
    assert_equal(1, @messages.length, 'Quality repeated on an unchanged frame')
  ensure
    close
    assert_equal([], @program.managed)
  end

  def all_five_shots
    setup_shots
    targets = trace.state[:model][:private][:targets]
    expected = [100, 75, 50, 25, 0]
    targets.each_with_index do |target, index|
      position = target + index <= 9 ? target + index : target - index
      step(0x30 + position)
      assert_equal(nil, request, 'The result overtook the final shot feedback')
      finish_feedback
    end
    assert_equal(5, shots.length)
    assert_equal(5, quacks.length)
    assert_equal(expected.map { |score| GameRoomDuckRacing::ChallengePresentation.shot_quality(score) }, @messages.map(&:last))
    assert_equal(expected, trace.state[:model][:results][0][:target_scores])
    assert_equal('submit_trace', request['action'])
    verifier = GameRoomDuckRacing::TraceVerifier.new(
      challenge: @replay.state[:round][:challenge], balances: {0 => 18, 1 => 18}, resources: resources
    )
    verifier.replay(traces: {0 => request['trace']}, forfeits: [1])
    saved = Marshal.dump(request)
    step(0x35)
    assert_equal(saved, Marshal.dump(request), 'A finished shot submitted twice')
  ensure
    close
  end

  def cancellation
    setup_shots
    step(0x35)
    close
    step(delta: 5_000)
    assert_equal([], @messages, 'Closing played queued feedback')
    assert_equal(1, quacks.length)
    assert_equal([], @program.managed)
  end

  def translations
    {
      'en' => %w[Perfect! Good! Fair! Poor! Miss!],
      'pl' => %w[Idealnie! Dobrze! Średnio! Słabo! Pudło!],
      'cs' => %w[Přesně! Dobře! Průměrně! Slabě! Vedle!],
      'es' => %w[¡Perfecto! ¡Bien! ¡Regular! ¡Flojo! ¡Fallo!],
      'ru' => %w[Точно! Хорошо! Средне! Слабо! Мимо!]
    }.each do |language, labels|
      GameRoomTestLocalization.use_language(language)
      assert_equal(labels, [100, 75, 50, 25, 0].map { |score| GameRoomDuckRacing::ChallengePresentation.shot_quality(score) })
    end
  ensure
    GameRoomTestLocalization.use_language('en')
  end
end

DuckShotFeedbackTest.new.run
