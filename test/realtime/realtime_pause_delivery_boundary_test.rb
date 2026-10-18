require_relative '../support/audio_ball_client'

module RealtimePauseDeliveryContract
  module_function

  def control(h, paused, epoch: 'initial', owner: 'Alice')
    h.clients.each_value do |client|
      client.update_table_control('__frozen' => paused, '__control_epoch' => epoch, '__table_owner' => owner)
    end
  end

  def turns(h)
    h.clients.transform_values do |client|
      h.is_a?(AudioBallHarness) ? client.engine.turn : pong_presented_turn(client)
    end
  end

  def queue(h, client)
    client.send(:rally_state).public_send(h.is_a?(AudioBallHarness) ? :deferred : :deferred_events)
  end

  def perform_held_serve(h)
    actor = h.players.fetch(h.clients.fetch('Alice').engine.server)
    channel = h.network.fetch(actor.downcase)
    channel.hold_events = true
    if h.is_a?(AudioBallHarness)
      h.surfaces.fetch(actor).push('prepare', 'up')
    else
      h.press(actor)
    end
    h.advance(1, names: [actor])
    expected = h.is_a?(AudioBallHarness) ? 2 : 1
    assert(h.clients.fetch(actor).engine.turn == expected, 'Fixture did not perform a legal serve')
    [actor, channel, expected]
  end

  def run(type, results, name)
    h = type.new
    begin
      details = yield h
      results << {case: "#{type}: #{name}", status: 'PASS', details: details}
    rescue StandardError => error
      results << {case: "#{type}: #{name}", status: 'FAIL', error: "#{error.class}: #{error.message}", at: error.backtrace.first}
    ensure
      h.close
    end
  end
end

results = []
[PongHarness, AudioBallHarness].each do |type|
  RealtimePauseDeliveryContract.run(type, results, 'freeze before the first frame and connection handshake') do |h|
    RealtimePauseDeliveryContract.control(h, true)
    h.advance(600)
    assert(RealtimePauseDeliveryContract.turns(h).values.all?(&:zero?), 'Initial pause generated a serve')
    assert(h.clients.values.all?(&:paused), 'Initial pause did not cover every viewer')
    assert(h.network.values.all? { |channel| channel.resets.zero? && !channel.sent.empty? }, 'Initial pause broke the channel handshake')
    RealtimePauseDeliveryContract.control(h, false)
    h.advance(20)
    assert(h.clients.values.none?(&:paused), 'Initial pause left normal play blocked after the handshake')
    assert(h.clients.values.all? { |client| client.context_data.values.compact.empty? }, 'Initial pause produced a point')
    {turns: RealtimePauseDeliveryContract.turns(h), reconnects: h.network.transform_values(&:resets)}
  end

  RealtimePauseDeliveryContract.run(type, results, 'authentic reliable serve delivered during a long pause, then delivered twice') do |h|
    h.advance(300)
    actor, channel, expected = RealtimePauseDeliveryContract.perform_held_serve(h)
    RealtimePauseDeliveryContract.control(h, true)
    channel.release_events
    h.advance(1)
    before = RealtimePauseDeliveryContract.turns(h)
    receiver = (h.players - [actor]).first
    assert(before.fetch(receiver).zero?, 'Reliable serve was applied while paused')
    assert(RealtimePauseDeliveryContract.queue(h, h.clients.fetch(receiver)).length >= 1, 'Paused serve was discarded instead of deferred')
    h.advance(700)
    assert(RealtimePauseDeliveryContract.turns(h) == before, 'Deferred action changed physics during pause')
    assert(h.network.values.all? { |endpoint| endpoint.resets.zero? }, 'Expected paused action disagreement forced reconnect')
    RealtimePauseDeliveryContract.control(h, false)
    h.advance(5)
    assert(RealtimePauseDeliveryContract.turns(h).values.all? { |turn| turn == expected }, 'Serve did not resume consistently for both players and observer')
    # Repeat genuine packets emitted by the actor, not fabricated transitions.
    channel.event_sent.each do |encoded|
      h.network.each do |name, endpoint|
        endpoint.event_inbox << [actor.downcase, JSON.parse(encoded)] unless name == actor.downcase
      end
    end
    h.advance(5)
    assert(RealtimePauseDeliveryContract.turns(h).values.all? { |turn| turn == expected }, 'Repeated reliable delivery repeated an accepted transition')
    assert(h.clients.values.all? { |client| client.context_data.values.compact.empty? }, 'Deferred serve awarded a point before flight completed')
    {turns: RealtimePauseDeliveryContract.turns(h), deferred: h.clients.transform_values { |client| RealtimePauseDeliveryContract.queue(h, client).length }}
  end

  RealtimePauseDeliveryContract.run(type, results, 'host and channel epoch change invalidate a paused old serve') do |h|
    h.advance(300)
    actor, channel, = RealtimePauseDeliveryContract.perform_held_serve(h)
    RealtimePauseDeliveryContract.control(h, true)
    channel.release_events
    h.advance(1)
    receiver = (h.players - [actor]).first
    assert(!RealtimePauseDeliveryContract.queue(h, h.clients.fetch(receiver)).empty?, 'Fixture did not queue the old epoch action')
    old_channels = h.network.dup
    RealtimePauseDeliveryContract.control(h, true, epoch: 'new-controller', owner: 'Bob')
    h.clients.each { |viewer, client| client.before_wait(h.replay, viewer) }
    h.advance(2)
    assert(h.clients.values.all? { |client| RealtimePauseDeliveryContract.queue(h, client).empty? }, 'New controller retained old reliable actions')
    assert(old_channels.values.none?(&:connected?), 'Old controller channels remained active')
    assert(h.network.all? { |name, endpoint| endpoint != old_channels.fetch(name) }, 'Controller epoch reused the old channel')
    RealtimePauseDeliveryContract.control(h, false, epoch: 'new-controller', owner: 'Bob')
    h.advance(30)
    assert(RealtimePauseDeliveryContract.turns(h).values.all?(&:zero?), 'Old controller serve was applied after host change')
    assert(h.clients.values.all? { |client| client.context_data.values.compact.empty? }, 'Old controller action produced a durable point')
    {turns: RealtimePauseDeliveryContract.turns(h)}
  end
end

RealtimePauseDeliveryContract.run(AudioBallHarness, results, 'two pauses preserve the active hurry timer and one timeout point') do |h|
  h.advance(300)
  owner = h.clients.fetch('Alice')
  caller = h.players.fetch(1 - owner.engine.holder)
  assert(h.clients.fetch(caller).send(:local_command, 'hurry'), 'Fixture failed to send Audio Ball hurry')
  h.advance(120)
  warnings = h.clients.transform_values { |client| client.engine.warning }
  assert(warnings.values.all? { |seconds| seconds && seconds.between?(7.9, 8.2) }, 'Fixture did not propagate the real warning')
  [350, 600].each do |frames|
    before = h.clients.transform_values { |client| client.engine.warning }
    RealtimePauseDeliveryContract.control(h, true)
    h.advance(frames / 2)
    RealtimePauseDeliveryContract.control(h, true)
    h.advance(frames - frames / 2)
    assert(h.clients.all? { |name, client| (client.engine.warning - before.fetch(name)).abs < 0.00001 }, 'Audio Ball warning counted paused time')
    RealtimePauseDeliveryContract.control(h, false)
    h.advance(30)
    assert(h.clients.all? { |name, client| (before.fetch(name) - client.engine.warning).between?(0.3, 0.55) }, 'Audio Ball warning jumped or stopped after resume')
  end
  remaining = owner.engine.warning
  h.advance_for(remaining - 0.1)
  assert(owner.context_data['audio_ball_point'].nil?, 'Hurry timeout point appeared before its remaining duration')
  h.advance_for(0.5)
  assert(owner.context_data['audio_ball_point'], 'Hurry timeout failed to produce one agreed point')
  assert(owner.context_data.fetch('audio_ball_point').end_with?(':timeout'), 'Hurry point lost its timeout reason')
  before_events = h.events.length
  h.commit
  h.advance(30)
  assert(h.events.length == before_events + 1 && owner.context_data['audio_ball_point'].nil?, 'Paused hurry repeated a committed point')
  assert(h.audios.values.all? { |audio| audio.calls.count { |call| call.first == :hurry } == 1 }, 'Pause repeated the hurry announcement')
  {warning_at_first_pause: warnings, accepted_events: h.events.length - before_events}
end

RealtimePauseDeliveryContract.run(PongHarness, results, 'arcade shield lifetime survives repeated pauses without catching up') do |h|
  h.advance(300)
  # This is the same engine effect used by an authenticated arcade event;
  # seed it identically only to isolate lifetime from random arcade chance.
  h.clients.each_value { |client| client.engine.send(:renew_shield, 0) }
  server = h.players.fetch(h.clients.fetch('Alice').engine.server)
  h.press(server)
  h.advance(10)
  [300, 500].each do |frames|
    before = h.clients.transform_values { |client| client.engine.shields.dup }
    RealtimePauseDeliveryContract.control(h, true)
    h.advance(frames)
    assert(h.clients.all? { |name, client| client.engine.shields == before.fetch(name) }, 'Shield lifetime advanced while paused')
    RealtimePauseDeliveryContract.control(h, false)
    h.advance(2)
    h.players.each do |name|
      delta = before.fetch(name).fetch(0) - h.clients.fetch(name).engine.shields.fetch(0)
      assert(delta.between?(0, 2), "#{name} shield consumed paused wall clock: #{delta}")
    end
  end
  {remaining_shields: h.clients.transform_values { |client| client.engine.shields }}
end

puts JSON.pretty_generate(results)
failures = results.reject { |result| result[:status] == 'PASS' }
raise "#{failures.length} realtime pause delivery boundaries failed" unless failures.empty?
puts 'PASS realtime pause delivery boundaries: cold handshake, reliable actions, duplicate delivery, host epoch, repeated hurry and shields'
