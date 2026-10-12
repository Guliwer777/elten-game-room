require_relative 'realtime_helpers'
require_relative '../../support/audio_ball_point_audio'

class DuckRealtimePointAudioTest
  include GameRoomTest::Assertions

  def assert(value, message = 'Assertion failed')
    @checks = (@checks || 0) + 1
    super
  end

  def run
    %w[axel_pong audio_ball].each do |kind|
      [false, true].each do |single|
        program = AudioBallPointTest::Program.new
        def program.communication; end
        type = kind == 'axel_pong' ? GameRoomPong::Client : GameRoomAudioBall::Client
        audio_type = kind == 'axel_pong' ? GameRoomPong::Audio : GameRoomAudioBall::Audio
        audio = audio_type.new(program, clock: -> { program.now }, speaker: ->(_text) { false })
        projection = GameRoomDuckRacing::RealtimeProjection.new({id: 1, kind: kind,
          participants: [0, 1], seed: 2}, %w[Alice Bob], owner: 'Host')
        child = type.new(program, projection.game, clock: -> { program.now }, audio: audio,
          channel_factory: ->(**args) { AudioBallTestChannel.new({}, **args) })
        begin
          child.bind_screen(session_id: 300, table_id: 20, owner: 'Host', viewer: 'Watcher',
            members: -> { %w[Host Alice Bob Watcher] }, single_point: single)
          child.before_wait(projection.replay, 'Watcher')
          child.start
          assert_equal(false, child.presentation_pending?)
          [-1, 2, nil, '1', 0.0].each do |bad|
            assert_equal(false, child.finish_single_point(winner: bad))
          end
          if single
            assert(child.finish_single_point(winner: 1))
            assert(child.presentation_pending?)
            assert_equal(false, child.finish_single_point(winner: 1))
            assert(program.sounds.values.none? { |sound| sound.closes.positive? }, 'Goal handles closed immediately')
            initial_count = program.events.length
            program.now = 0.2
            child.tick
            assert(child.presentation_pending?, 'Goal was cut before recording end')
            program.now = 0.36
            child.tick
            assert_equal(false, child.presentation_pending?)
            assert_equal(initial_count, program.events.length, 'A score/full-match result started after the goal')
            assert_equal(nil, projection.replay.winner, 'Finishing native projection mutated caller replay')
            assert_equal(nil, GameRoomPing.for(program).communications_channel)
            # Closing an old finishing client must not unregister a newer
            # game's channel, which may already own Ctrl+F4 in the race.
            newer_channel = Object.new
            GameRoomPing.for(program).communications_channel = newer_channel
            child.close
            assert_equal(newer_channel, GameRoomPing.for(program).communications_channel)
            assert(program.sounds.values.all? { |sound| sound.closes == 1 })
            assert(program.sounds.values.all? { |sound| sound.interruptions.zero? }, 'Completed goal was interrupted')
          else
            assert_equal(false, child.finish_single_point(winner: 1), 'Ordinary match accepted single-point termination')
            assert_equal([], program.events)
            assert_equal(false, child.instance_variable_get(:@replay).finished?)
            assert(child.instance_variable_get(:@channel).connected?)
          end
        ensure
          child.close
        end
      end

      invalid = [nil, 0, 1, 'true', []]
      invalid.each do |value|
        factory_calls = []
        type = kind == 'axel_pong' ? GameRoomPong::Client : GameRoomAudioBall::Client
        child = type.new(Program.new, kind == 'axel_pong' ? GameRoomGames::AxelPong.new : GameRoomGames::AudioBall.new,
          audio: kind == 'axel_pong' ? PongTestAudio.new : AudioBallTestAudio.new,
          channel_factory: ->(**args) { factory_calls << args })
        begin
          assert_raises(ArgumentError) do
            child.bind_screen(session_id: 300, table_id: 20, owner: 'Alice', viewer: 'Alice',
              members: -> { [] }, single_point: value)
          end
          assert_equal([], factory_calls)
          assert_equal(false, child.instance_variable_defined?(:@activity_table))
        ensure
          child.close
        end
      end
    end

    program = AudioBallPointTest::Program.new
    audio = GameRoomAudioBall::PointAudio.new(program, clock: -> { program.now },
      speaker: ->(_text) { true }, speech_active: -> { true })
    begin
      audio.load
      audio.announce('Server notice')
      assert(audio.announcement_pending?)
      program.now = 30.1
      audio.tick
      assert_equal(false, audio.announcement_pending?, 'Speech pending outlived its existing deadline')
      audio.goal(viewer: 0, winner: 0)
      assert(audio.announcement_pending?)
      program.enabled = false
      audio.tick
      assert_equal(false, audio.announcement_pending?, 'Muted presentation could not be retired')
    ensure
      audio.close
    end
    puts "PASS Duck opt-in point ending and real audio queue lifetime: #{@checks} checks"
  end
end

DuckRealtimePointAudioTest.new.run
