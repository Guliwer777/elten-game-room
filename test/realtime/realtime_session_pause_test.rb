require_relative '../support/audio_ball_client'

def durable_pause(harness, paused, names: harness.clients.keys)
  names.each do |name|
    harness.clients.fetch(name).update_table_control(
      '__frozen' => paused, '__control_epoch' => 'initial',
      '__table_owner' => 'Alice')
  end
end

def captured_engines(harness)
  harness.clients.transform_values { |client| Marshal.load(Marshal.dump(client.engine.snapshot)) }
end

[
  [PongHarness, %w[Alice Bob], {}],
  [PongHarness, %w[Alice Bob Carol Diana], {'team_size' => 2, 'team_seats' => [0, 0, 1, 1]}],
  [PongHarness, %w[Alice bot:7:1], {}],
  [AudioBallHarness, %w[Alice Bob], {}],
  [AudioBallHarness, %w[Alice bot:7:1], {}]
].each do |type, players, options|
  viewers = players.reject { |name| GameRoomParticipants.bot?(name) } + ['Watcher']
  h = type.new(players: players, viewers: viewers, options: options)
  begin
    h.advance(300)
    durable_pause(h, false)
    server = players[h.clients['Alice'].engine.server]
    if type == PongHarness
      h.press(server) unless GameRoomParticipants.bot?(server)
      h.advance(10)
      assert(h.clients['Alice'].engine.ball['dy'] != 0, "#{type} fixture did not serve")
    else
      h.press(server, 'prepare', 'up') unless GameRoomParticipants.bot?(server)
      h.advance(10)
      assert(h.clients['Alice'].engine.phase == :flying, "#{type} fixture did not serve")
    end
    channels = h.network.transform_values(&:object_id)
    sends = h.network.transform_values { |channel| channel.sent.length }
    durable_pause(h, true)
    h.advance(1)
    before = captured_engines(h)
    1_000.times do |index|
      if (index % 100).zero?
        durable_pause(h, true) # A quiet refresh must not restart the pause.
        viewers.each do |name|
          if type == PongHarness
            h.press(name, move: index.even? ? 1 : -1)
          else
            h.surfaces[name].push('prepare', 'up', 'left', 'down')
          end
        end
      end
      h.advance(1)
    end
    assert(captured_engines(h) == before, "#{type}/#{players}: physics changed during durable pause")
    assert(h.clients.values.all?(&:paused), "#{type}: a client left durable pause")
    assert(h.clients.values.all? { |client| client.context_data.values.compact.empty? }, "#{type}: pause produced a point")
    assert(h.network.all? { |name, channel| channel.object_id == channels[name] && channel.resets.zero? },
      "#{type}: healthy paused networking unnecessarily reconnected")
    assert(h.network.all? { |name, channel| channel.sent.length > sends[name] }, "#{type}: pause stopped transport acknowledgements")
    assert(!h.clients['Alice'].send(type == PongHarness ? :request_hurry : :local_command, *([type == PongHarness ? nil : 'hurry'].compact)),
      "#{type}: hurry accepted during pause")
    h.surfaces.each_value { |surface| surface.controls['move'] = 0 if surface.respond_to?(:controls) }
    durable_pause(h, false)
    h.advance(2)
    after = captured_engines(h)
    assert(h.clients.values.none?(&:paused), "#{type}: normal play did not resume")
    assert(h.clients.values.all? { |client| client.context_data.values.compact.empty? }, "#{type}: resume consumed paused time as a point")
    if type == PongHarness
      assert(after['Alice']['tick'] <= before['Alice']['tick'] + 2, 'Pong caught up paused physics frames')
      assert(after['Alice']['turn'] == before['Alice']['turn'], 'Pong replayed a paused key press')
    else
      assert((after['Alice']['position'] - before['Alice']['position']).abs < 1, 'Audio Ball caught up paused flight')
      assert(after['Alice']['turn'] == before['Alice']['turn'], 'Audio Ball replayed a paused command')
    end
  ensure
    h.close
  end
end

# A pending serve warning retains its unspent duration through a long pause.
h = PongHarness.new
begin
  h.advance(300)
  owner = h.clients['Alice']
  caller = h.clients[h.players[1 - owner.engine.server]]
  assert(caller.request_hurry, 'Pong hurry setup failed')
  h.advance(100)
  remaining = owner.instance_variable_get(:@hurry_until) - h.now
  durable_pause(h, true)
  h.advance(1_000)
  assert(owner.context_data['pong_point'].nil?, 'Pong pause consumed the warning')
  durable_pause(h, false)
  assert((owner.instance_variable_get(:@hurry_until) - h.now - remaining).abs < 0.00001,
    'Pong pause did not preserve the remaining warning')
  h.advance((remaining / 0.016).floor - 2)
  assert(owner.context_data['pong_point'].nil?, 'Pong warning expired too early after pause')
  h.advance(20)
  assert(owner.context_data['pong_point']&.end_with?(':timeout'), 'Pong warning never expired after resume')
ensure
  h.close
end

puts 'PASS durable realtime pause: human/bot Single, Doubles, Audio Ball, observers, ACKs, input drain, resume and hurry'
