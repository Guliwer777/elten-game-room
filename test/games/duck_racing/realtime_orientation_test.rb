require_relative 'realtime_helpers'
include GameRoomTest::Assertions

h=DuckRealtimeHarness.new(kind:'audio_ball')
begin
  h.programs.each_value do |program|
    program.define_singleton_method(:audio_ball_preferences){GameRoomAudioBall::Preferences.normalize('listening_side'=>'left')}
  end
  h.advance(50)
  h.viewers.each do |viewer|
    audio=h.audios.fetch(viewer)
    lines=audio.calls.select{|call|call.first==:announce}.map(&:last)
    expected=viewer=='Bob' ? 'Bob is on the left; Alice is on the right.' : 'Alice is on the left; Bob is on the right.'
    assert(lines.include?(expected),"Missing orientation for #{viewer}: #{lines}")
    assert_equal(1,lines.count(expected))
    h.programs.fetch(viewer).define_singleton_method(:audio_ball_preferences){GameRoomAudioBall::Preferences.normalize('listening_side'=>'right')}
  end
  h.advance(30)
  h.viewers.each do |viewer|
    lines=h.audios.fetch(viewer).calls.select{|call|call.first==:announce}.map(&:last)
    expected=viewer=='Bob' ? 'Alice is on the left; Bob is on the right.' : 'Bob is on the left; Alice is on the right.'
    assert_equal(1,lines.count(expected),'Changed preference repeated or lost orientation')
  end
ensure
  h.close
end

h=DuckRealtimeHarness.new(kind:'axel_pong')
begin
  $spoken_messages.clear
  h.advance(50)
  assert($spoken_messages.any?{|line|line.start_with?('Watching Alice.') && line.include?('serves.')},'Spectator did not hear perspective and server')
  watcher=h.created.find{|client|client.instance_variable_get(:@viewer)=='Watcher'}
  surface=GameSurfaces.build(h.wrappers['Watcher'].projection.game.surface_spec(h.wrappers['Watcher'].projection.replay,'Watcher'))
  watcher.attach_view(Form.new(surface.fields),surface)
  $spoken_messages.clear
  surface.handle_command('perspective_second')
  assert($spoken_messages.last.start_with?('Watching Bob.') && $spoken_messages.last.include?('serves.'),'Perspective change lost current server')
  assert_equal(nil,watcher.instance_variable_get(:@side),'Perspective gave spectator control')
ensure
  h.close
end
puts 'PASS Duck realtime orientation: both players, spectators, listening preferences, single announcement and Pong perspective without control'
