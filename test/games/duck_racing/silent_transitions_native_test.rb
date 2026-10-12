# frozen_string_literal: true

require_relative '../../support/duck_challenge_native'
require_relative '../../support/duck_game_adapter'
require_relative 'client_helpers'
require_relative '../../../lib/game_event_presenter'

class DuckSilentTransitionsNativeTest
  include DuckClientTest

  def run
    @real_controls = true
    @driver = DuckChallengeNativeDriver.new
    race_start
    simon
    report('Duck silent transitions: native focus/speech, actual client playback/input, race history and effects')
  end

  def texts
    SpeechOutput.calls.map(&:first)
  end

  def refute_playback_prompts
    assert(texts.none? { |text| text.match?(/\bListen\.|\bRepeat\.|\b\d+ sounds?\./) },
      "Playback instructions escaped through speech/focus: #{texts.inspect}")
  end

  def race_start
    h = DuckGameAdapterTest::Harness.new
    SpeechOutput.reset
    surface = GameSurfaces.build(h.game.surface_spec(h.replay, 'Alice'))
    form = @driver.form(surface)
    @driver.frame(form)
    surface.fields.first.focus
    assert(texts.none? { |text| text.include?('Preparing the race.') }, 'Native initial focus announced preparation')
    assert_equal('Preparing the race.', h.game.turn_text(h.replay), 'Manual preparation status was removed')

    @program = DuckChallengeAudioTest::Program.new
    output = GameRoomSoundOutput.new(@program, audio_game: true, covered: -> { false })
    presenter = GameRoomEventPresenter.new(game: -> { h.game }, repository: -> { h.repository },
      program: -> { @program }, viewer: -> { 'Alice' }, client: -> { nil }, surface_state: -> { {} },
      clock: -> { @program.now_ms / 1000.0 }, covered: -> { false },
      speech: ->(text) { speak(text, stop: false, break_sequence: false) },
      trace: ->(*_args, **_options) {}, history_changed: ->(*_args) {}, session_changed: -> {})
    presenter.process_new_events(h.replay, session: h.session)
    h.open_round
    presenter.process_new_events(h.replay, session: h.session)
    assert(texts.none? { |text| text.include?('The race has started.') }, 'EventPresenter spoke the startup marker')
    assert(h.replay.history.any? { |entry| entry.kind == :started && entry.text == 'The race has started.' },
      'Silencing startup removed the canonical race boundary')
    assert(@program.events.any? { |entry| entry[:asset] == 'shuffle' }, 'Silencing startup also removed its sound')
    h.begin_round
    presenter.process_new_events(h.replay, session: h.session)
    h.finish_private
    after = h.replay
    presenter.process_new_events(after, session: h.session)
    result = after.history.find { |entry| entry.kind == :challenge_result }
    assert(result && result.text.include?('feather'), 'Fixture has no actual transfer to inspect')
    1_000.times do
      break unless presenter.event_presentation_busy?
      @program.now_ms += 100
      presenter.event_presentation.advance
    end
    assert(!presenter.event_presentation_busy?, 'Result presentation did not finish')
    result.text.lines(chomp: true).each do |line|
      assert_equal(1, texts.flat_map { |text| text.lines(chomp: true) }.count(line),
        'Silencing startup removed or duplicated the final result or feather transfer')
    end
    spoken = texts.dup
    3.times { presenter.process_new_events(after, session: h.session) }
    assert_equal(spoken, texts, 'Refresh repeated the result')
  ensure
    output&.close
  end

  def frame(events = [], milliseconds: 25)
    @program.now_ms += milliseconds
    @driver.frame(@form, events)
    @client.tick
  end

  def wait_until_response
    200.times do
      frame
      return if @client.local_view.dig(:own, :phase) == :responding
    end
    raise 'The real local playback did not reach the answering phase'
  end

  def simon
    SpeechOutput.reset
    setup_client('simon')
    @surface = GameSurfaces.build(@client.surface_spec(@replay, @viewer))
    @form = @driver.form(@surface)
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
    field, chat = @surface.fields.first, @form.fields.last
    assert(texts.any? { |text| text.include?('with 1 to 5') }, 'Initial focus lost the actual controls')
    # This helper focuses before attaching the client; the actual quiet
    # GameScreen wait clears the newly installed one-shot focus suppression.
    # Model that boundary before explicitly focusing the field again below.
    field.clear_suppressed_focus!
    refute_playback_prompts

    3.times do
      wait_until_response
      before_focus = texts.length
      field.focus
      assert(texts.length > before_focus, 'The native manual field read did not run')
      refute_playback_prompts
      trace = @client.instance_variable_get(:@trace)
      level = @client.local_view.dig(:own, :level)
      trace.state[:model][:private][:sequence].first(level).each do |tone|
        frame(@driver.tap(0x30 + tone))
      end
      assert_equal(level + 1, @client.local_view.dig(:own, :level))
      assert_equal(:listening, @client.local_view.dig(:own, :phase))
      refute_playback_prompts
    end
    assert(@program.events.length >= 9, 'Removing speech also stopped the sequence sounds')

    frame(@driver.tap(0x09))
    assert_equal(chat, @form.fields[@form.index])
    draft, focus, speech = chat.text.dup, @form.index, texts.dup
    wait_until_response
    assert_equal(focus, @form.index, 'Playback completion stole chat focus')
    assert_equal(draft, chat.text)
    assert_equal(speech, texts, 'Playback completion spoke over chat')
    recorded_inputs = @client.instance_variable_get(:@trace).instance_variable_get(:@actions)
    before_inputs = recorded_inputs.length
    frame(@driver.tap(0x31))
    assert_equal(before_inputs, recorded_inputs.length,
      'A key on chat became a Simon answer')

    frame(@driver.tap(0x09, modifiers: [0x10]))
    assert_equal(field, @form.fields[@form.index])
    refute_playback_prompts
    expected = @client.instance_variable_get(:@trace).state[:model][:private][:sequence].first
    wrong = expected % 5 + 1
    frame(@driver.tap(0x30 + wrong))
    assert_equal('submit_trace', request['action'], 'Silencing phases stopped completion')
    assert(texts.include?('Waiting for others.'), 'Finished attempt lost its status')
    final = texts.dup
    5.times { frame }
    assert_equal(final, texts, 'A stable finished attempt kept speaking')
    refute_playback_prompts
  ensure
    $lastactivecontrols = []
    close
  end
end

DuckSilentTransitionsNativeTest.new.run
