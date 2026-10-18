require_relative "../support/sequence_random"

require_relative "../support/background_help_game_screen"

[:f1, :rules].each do |kind|
  h, screen = screen_fixture(GameRoomGames::FourInARow.new)
  layout, help, stage = nil, nil, 0
  Form.driver = lambda do |form|
    layout = screen.instance_variable_get(:@layout)
    assert(form.equal?(layout.form), 'Help entered a nested blocking wait')
    if stage == 0
      if kind == :f1
        form.show_game_room_help
      else
        screen.send(:show_game_rules, h.replay('Alice'))
        form.game_room_background_help_form.accept_button.trigger(:press)
      end
      help = form.game_room_background_help_form
      help.fields.first.index = 17
      h.write('Alice', [GameRoomGames::EventCommand.new(action: 'drop', value: '1')])
      h.write('Bob', [GameRoomGames::EventCommand.new(action: 'drop', value: '7')])
      stage = 1
    elsif stage == 1 && screen.send(:event_presenter).instance_variable_get(:@last_seen_event_id).to_i >= h.events('Alice').last['__id'].to_i
      assert(form.game_room_background_help_form.equal?(help) && help.fields.first.index == 17,
        'Remote replay replaced help or its cursor')
      assert(layout.history.items.any? { |text| text.include?('Bob') }, 'Remote move did not reach the visible history')
      form.clear_game_room_background_help
      layout.back_button.trigger(:press)
      stage = 2
    end
  end
  h.as('Alice') { assert(screen.run == :back, 'Help changed the normal room exit') }
  assert(stage == 2 && !layout.form.game_room_background_help?, 'Help blocked replay or leaked after exit')
  h.assert_converged("#{kind} remote replay", expected_count: 2)
  puts "PASS #{kind}: GameScreen consumes incoming turn-based moves and updates history without closing help"
end

h, screen = screen_fixture(GameRoomGames::FourInARow.new, bots: 1)
opened = nil
Form.driver = lambda do |form|
  layout = screen.instance_variable_get(:@layout)
  unless opened
    form.show_game_room_help
    opened = form.game_room_background_help_form
    h.write('Alice', [GameRoomGames::EventCommand.new(action: 'drop', value: '1')])
  end
  if h.replay('Alice').accepted_events.length >= 2
    assert(form.game_room_background_help_form.equal?(opened), 'Bot calculation lost the open help')
    form.clear_game_room_background_help
    layout.back_button.trigger(:press)
  end
end
h.as('Alice') { screen.run }
assert(h.replay('Alice').accepted_events.length == 2, 'Bot did not submit exactly one reply while help was open')
puts 'PASS F1: normal bot planning, repository submission and replay continue behind help'

[:f1, :tutorial].each do |kind|
  game = GameRoomGames::AudioBall.new
  clock = -> { $help_clock }
  network, audio = {}, AudioBallTestAudio.new
  client = GameRoomAudioBall::Client.new(Program.new, game, clock: clock, audio: audio,
    channel_factory: ->(**args) { AudioBallTestChannel.new(network, **args) })
  game.define_singleton_method(:build_client) { |_program, **_services| client }
  h, screen = screen_fixture(game, bots: 1)
  bot_serves_audio_ball(h)
  help, score_changes, last_rally = nil, 0, 0
  Form.driver = lambda do |form|
    layout = screen.instance_variable_get(:@layout)
    assert(form.equal?(layout.form), 'Realtime help entered a blocking wait')
    unless help
      if kind == :f1
        form.show_game_room_help
      else
        screen.send(:show_game_rules, h.replay('Alice'))
        picker = form.game_room_background_help_form
        picker.fields.first.index = picker.fields.first.options.length - 1
        picker.accept_button.trigger(:press)
      end
      help = form.game_room_background_help_form
      help.fields.first.index = kind == :f1 ? 11 : 2
    end
    assert(form.game_room_background_help_form.equal?(help), 'Point refresh closed realtime help')
    rally = h.replay('Alice').state[:rally]
    if rally > last_rally
      score_changes += 1
      last_rally = rally
    end
    # The shared worker may finish the durable write before the next UI frame
    # presents it. Do not close the screen at that intermediate boundary.
    if score_changes >= 2 && audio.calls.count { |call| call.first == :point } >= 2
      assert(help.fields.first.index == (kind == :f1 ? 11 : 2), 'Point refresh reset the reading/preview position')
      form.clear_game_room_background_help
      layout.back_button.trigger(:press)
    end
  end
  h.as('Alice') { screen.run }
  point_events = h.events('Alice').select { |event| event['action'] == 'audio_ball_point' }
  assert(point_events.length == 2, 'Help stopped durable automatic point writes')
  assert(audio.calls.count { |call| call.first == :point } == 2, 'Point presentation did not continue behind help')
  assert(network['alice'].reasons.empty?, 'Help caused a realtime reconnect')
  puts "PASS #{kind}: two bot rallies, durable points, result presentation and next server continue in real GameScreen"
end

# More than the old 10-second status timeout, with both real playfields behind
# help. A warning received from the peer must still expire in the game engine.
h = AudioBallHarness.new(viewers: %w[Alice Bob])
forms = h.players.to_h do |name|
  surface = GameSurfaces.build(h.game.surface_spec(h.replay, name))
  form = GameRoomUI::Form.new(surface.fields, quiet: true)
  form.game_room_background_help_enabled = true
  h.clients[name].attach_view(form, surface)
  form.show_game_room_help
  [name, form]
end
warned, committed = false, false
2500.times do
  h.now += 0.016
  forms.each_value(&:update)
  if h.now >= 15 && !warned
    assert(h.clients.values.none?(&:paused), 'Help stopped peer heartbeats before the warning')
    assert(h.clients['Bob'].send(:local_command, 'hurry'), 'Peer could not issue a normal warning')
    warned = true
  end
  if !committed && h.clients['Alice'].context_data['audio_ball_point']
    assert(h.now >= 25 && h.now < 26, 'Help changed the received ten-second warning deadline')
    h.commit
    committed = true
  end
end
assert(committed && h.replay.state[:last_point][:timeout], 'Help prevented an opponent warning from expiring')
assert(h.network.values.all? { |channel| channel.reasons.empty? }, 'Open help caused a peer timeout/reconnect')
assert(h.clients.values.none?(&:paused), 'Peers failed to resume normally while help stayed open')
forms.each_value do |form|
  assert(form.game_room_background_help?, 'A received timeout closed the reader')
  form.clear_game_room_background_help
end
h.close
puts 'PASS peer help: 40 seconds on two clients, simulated heartbeats, received warning, timeout point and next serve'
