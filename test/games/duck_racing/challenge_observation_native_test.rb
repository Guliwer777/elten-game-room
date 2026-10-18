# frozen_string_literal: true

require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'

class DuckChallengeObservationNativeTest
  include DuckClientTest

  def run
    @real_controls = true
    @driver = DuckChallengeNativeDriver.new
    %w[Charlie Watcher].each do |viewer|
      (GameRoomDuckRacing::Challenges::BY_ID.keys - ENGINE::REALTIME).each do |kind|
        verify(kind, viewer)
      end
      %w[simon rhythm hit_duck sound_memory audio_ball axel_pong].each do |kind|
        verify(kind, viewer, phase: :preparing)
      end
    end
    report('Duck observer native controls: readable public choices, no actions, chat and silent refresh')
  end

  def key_frame(code, characters: '')
    @program.now_ms += 16
    @driver.frame(@form, @driver.tap(code), characters: characters)
    @client.tick
  end

  def verify(kind, viewer, phase: :playing)
    setup_client(kind, viewer: viewer, phase: phase)
    @surface = GameSurfaces.build(@client.surface_spec(@replay, @viewer))
    @form = @driver.form(@surface)
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
    field = @surface.fields.first
    assert(!field.is_a?(EditBox), "#{kind}: observer received an answer edit")
    assert_equal(false, @surface.presentation[:enabled])
    snapshot = Marshal.dump(@replay.state)
    [0x0D, 0x20, 0x31, 0x32, 0x46, 0x4A, 0x74].each { |code| key_frame(code) }
    assert_equal(nil, request, "#{kind}: observer key became a game command")
    assert_equal(snapshot, Marshal.dump(@replay.state), "#{kind}: observer changed game state")
    assert_equal([], @program.events, "#{kind}: observer replayed private stimuli or a countdown")
    if phase == :playing && %w[quiz numbered_balls].include?(kind)
      start = field.index
      key_frame(0x28)
      assert(field.index != start, "#{kind}: read-only choices cannot be browsed")
      assert_equal(nil, request)
    end
    key_frame(0x09)
    chat = @form.fields.last
    assert_equal(chat, @form.fields[@form.index], "#{kind}: observer cannot reach chat")
    key_frame(0x58, characters: 'x')
    draft = chat.text.dup
    assert(draft.include?('x'), "#{kind}: chat did not accept native text")
    SpeechOutput.calls.clear
    replace
    assert_equal([], SpeechOutput.calls, "#{kind}: refresh replayed instructions")
    key_frame(0x59, characters: 'y')
    assert_equal(chat, @form.fields[@form.index], "#{kind}: refresh stole chat focus")
    assert(chat.text.include?('x') && chat.text.include?('y'), "#{kind}: refresh lost the draft")
  ensure
    close
  end
end

DuckChallengeObservationNativeTest.new.run
