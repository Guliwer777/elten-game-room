# frozen_string_literal: true

require_relative 'realtime_helpers'
include GameRoomTest::Assertions

%w[audio_ball axel_pong].each do |kind|
  # Carol is still playing the race; Watcher is not a racer at all. The
  # latter also coordinates the existing native point, without owning input.
  h = DuckRealtimeHarness.new(kind: kind, racers: %w[Alice Bob Carol], pair: [0, 1], owner: 'Watcher')
  begin
    h.advance(50)
    %w[Carol Watcher].each do |viewer|
      wrapper = h.wrappers.fetch(viewer)
      native = wrapper.native_client
      assert_equal(nil, native.instance_variable_get(:@side), "#{kind}: observer gained a player side")
      assert_equal(%w[Alice Bob], wrapper.projection.players)
      assert_equal(kind, wrapper.projection.surface_spec(viewer).game_id)
      if kind == 'axel_pong'
        surface = GameSurfaces.build(wrapper.projection.game.surface_spec(wrapper.projection.replay, viewer))
        native.attach_view(Form.new(surface.fields), surface)
        $spoken_messages.clear
        surface.handle_command('perspective_second')
        assert($spoken_messages.any? { |line| line.start_with?('Watching Bob.') }, 'Observer perspective was not announced')
        assert_equal(nil, native.instance_variable_get(:@side), 'Perspective change gave racket controls')
      else
        h.surfaces.fetch(viewer).push('prepare', 'up')
        h.surfaces.fetch(viewer).push('hit', 'up')
      end
    end
    # No human participant has served. Spectator controls do not start play.
    h.advance(10)
    assert_equal(nil, h.wrappers.fetch('Watcher').context_data['duck_realtime_point'])
    receipt = h.complete_native_point
    assert(receipt && [0, 1].include?(receipt['winner']), 'No verified point receipt')
    h.wrappers.each_value { |wrapper| assert(wrapper.finish_point(receipt), 'Accepted point was rejected by an observer') }
    h.advance(20)
    %w[Carol Watcher].each do |viewer|
      assert(h.audios.fetch(viewer).calls.any? { |entry| entry.first == :goal }, "#{kind}: observer missed accepted point audio")
      assert_equal(nil, h.wrappers.fetch(viewer).native_client, "#{kind}: completed observer channel remained alive")
    end
  ensure
    h.close
  end
end

puts 'PASS native Duck audio games: racer outside challenge and spectator host, perspective, no player controls and point audio'
