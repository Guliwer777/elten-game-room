require_relative '../../support/duck_challenge_native'
require_relative 'client_helpers'

class DuckPracticeStartTest
  include DuckClientTest

  def run
    @driver = DuckChallengeNativeDriver.new
    @real_controls = true
    {simon: (0x31..0x35).to_a, hit_duck: (0x31..0x39).to_a,
      rhythm: [0x46, 0x4A], audio_ball: [0x57, 0x44, 0x53, 0x26, 0x25, 0x28], axel_pong: []}.each do |kind, keys|
      [0x0D, 0x20].each { |start| practice(kind.to_s, keys, start) }
    end
    ball_duration_and_pack
    watcher_and_failure
    report('Duck manual preparation: native keys, previews, two-player readiness, lifecycle and ball packs')
  end

  def attach_native
    @surface = GameSurfaces.build(@client.surface_spec(@replay, @viewer))
    @form = @driver.form(@surface)
    @client.attach_view(@form, @surface)
    $lastactivecontrols = [@form]
  end

  def key(code = nil, held: [], repeat: false)
    @program.now_ms += 20
    events = code ? (repeat ? [[code, :repeat]] : @driver.tap(code)) : []
    @driver.frame(@form, events, held: held)
    @client.tick
  end

  def practice(kind, keys, start)
    setup_client(kind, phase: :preparing)
    attach_native
    assert(@surface.fields.first.is_a?(Button))
    assert(@client.local_view[:practice])
    assert_equal(false, @client.context_data['duck_ready'])
    if kind == 'axel_pong'
      assert(!@wrappers.last.active?, 'The rally started before either player was ready')
      assert(@surface.presentation[:instruction].include?('Left and Right'))
      assert(@surface.presentation[:instruction].include?('Up or Space'))
      assert(@surface.presentation[:instruction].include?('Press Enter'))
      [0x25, 0x27, 0x26].each { |code| key(code) }
      assert_equal(false, @client.context_data['duck_ready'], 'A movement key confirmed readiness')
    end
    keys.each do |code|
      key(code)
      key
    end
    assert_equal(keys.length, @program.events.length, "#{kind}: preview key lost")
    assert_equal(nil, @client.instance_variable_get(:@trace))
    assert_equal(nil, @replay.state[:round][:engine])
    assert_equal(nil, request, 'A practice key was sent to the server')
    case kind
    when 'simon'
      pitches = @program.events.map { |event| event[:frequency] }
      assert_equal(pitches.sort, pitches)
      assert_equal(5, pitches.uniq.length)
    when 'hit_duck'
      assert_equal((-4..4).map { |value| value / 4.0 }, @program.events.map { |event| event[:pan] })
    when 'rhythm'
      assert_equal(%w[duck_rhythm_f duck_rhythm_j], @program.events.map { |event| event[:asset] })
      assert_equal([48_000, 48_000], @program.events.map { |event| event[:frequency] })
    when 'audio_ball'
      assert_equal(%w[audio_ball_up audio_ball_left audio_ball_down] * 2, @program.events.map { |event| event[:asset] })
    end
    # Going to chat must neither confirm readiness nor play a sample.
    key(0x09)
    count = @program.events.length
    key(start)
    assert_equal(false, @client.context_data['duck_ready'])
    assert_equal(count, @program.events.length)
    key(0x09)
    key(start)
    assert_equal(true, @client.context_data['duck_ready'])
    assert_equal(false, @surface.presentation[:enabled])
    assert(@program.sounds.none?(&:playing?), 'Starting left the practice sample playing')
    key(keys.first)
    assert_equal(count, @program.events.length, 'Practice continued after readiness')

    state = @replay.state
    at = 100_000 + @program.now_ms
    [0, 1].each do |seat|
      action = {'action' => 'ready', 'challenge' => 1, 'fingerprint' => FINGERPRINT}
      assert(GameRoomDuckRacing::Session.apply(state, action, seat: seat, moderator: seat.zero?, now_ms: at, resources: resources))
      assert_equal(nil, GameRoomDuckRacing::Session.automatic(state, now_ms: at)) if seat.zero?
    end
    assert_equal('begin', GameRoomDuckRacing::Session.automatic(state, now_ms: at))
    assert(GameRoomDuckRacing::Session.apply(state, {'action' => 'begin', 'challenge' => 1, 'revision' => state[:revision]},
      seat: 0, moderator: true, now_ms: at, resources: resources))
    @client.before_wait(@replay, @viewer)
    assert(!@client.local_view&.[](:practice))
    if ENGINE::REALTIME.include?(kind)
      assert(@wrappers.last.active?)
    else
      attach_native
      key(start, held: [start], repeat: true)
      trace = @client.instance_variable_get(:@trace)
      assert(trace)
      assert_equal(0, trace.state[:last_press][0], 'Start key leaked into the scored attempt')
      assert_equal(nil, request)
    end
  ensure
    close
    assert_equal([], @program.managed)
  end

  def ball_duration_and_pack
    %w[default audiodisc].each do |pack|
      setup_client('audio_ball', phase: :preparing)
      @program.define_singleton_method(:audio_ball_preferences) { {'sound_pack' => pack} }
      attach_native
      key(0x57)
      key
      sound = @program.events.last[:sound]
      assert_equal(GameRoomAudioBall::SoundPack::PACKS[pack]['up'], sound.asset)
      onset = @program.events.last[:at]
      advance(onset + 1_980)
      assert(sound.playing?)
      advance(onset + 2_000)
      assert(!sound.playing?)
      assert_equal(false, @client.context_data['duck_ready'])
      close
    end
  ensure
    close
  end

  def watcher_and_failure
    warning = Log.method(:warning)
    warnings = []
    Log.define_singleton_method(:warning) { |text| warnings << text }
    setup_client('simon', phase: :preparing, viewer: 'Charlie')
    attach_native
    key(0x31)
    key(0x0D)
    assert_equal([], @program.events)
    assert_equal(false, @client.context_data['duck_ready'])
    close
    setup_client('simon', phase: :preparing)
    attach_native
    @program.missing = true
    key(0x31)
    key
    assert_equal('cancel', request['action'])
    assert_equal(false, @client.context_data['duck_ready'])
    assert_equal(1, warnings.length)
  ensure
    close
    Log.define_singleton_method(:warning, warning) if warning
  end
end

DuckPracticeStartTest.new.run
