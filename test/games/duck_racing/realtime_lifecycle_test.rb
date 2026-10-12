require_relative 'realtime_helpers'

class DuckRealtimeLifecycleTest
  include GameRoomTest::Assertions
  def assert(value, message = 'Assertion failed')
    @checks = (@checks || 0) + 1
    super
  end

  def run
    %w[axel_pong audio_ball].each do |kind|
      tail_and_next_challenge(kind)
      controller_changes(kind)
      human_and_bot(kind)
      invalid_projection(kind)
      timeout_point(kind)
    end
    puts "PASS Duck realtime lifecycle, bots and epoch isolation: #{@checks} checks"
  end

  def tail_and_next_challenge(kind)
    h = DuckRealtimeHarness.new(kind: kind)
    begin
      receipt = h.complete_native_point
      old_clients = h.wrappers.transform_values(&:native_client)
      old_channels = h.network.dup
      old_matches = old_clients.transform_values { |client| client.instance_variable_get(:@match) }
      h.wrappers.each_value { |wrapper| assert(wrapper.finish_point(receipt)) }
      assert(h.wrappers.values.any?(&:presentation_pending?), 'Goal tail was already cut on acceptance')
      h.parent.state[:race][:challenge] = h.parent.state[:race][:challenge].merge(id: 2)
      h.wrappers.each do |name, wrapper|
        assert_equal(false, wrapper.before_wait(h.parent, name), 'Next challenge cut the current goal')
        assert_equal(old_clients[name], wrapper.native_client)
        assert_equal(nil, wrapper.context_data['duck_realtime_point'])
      end
      h.advance(20)
      h.wrappers.each do |name, wrapper|
        assert_equal(nil, wrapper.native_client)
        assert(wrapper.before_wait(h.parent, name))
        h.attach(name)
        assert(wrapper.active?)
        assert(old_matches[name] != wrapper.native_client.instance_variable_get(:@match), 'Two challenges reused their channel')
        assert_equal(false, wrapper.finish_point(receipt), 'Old accepted point ended the next challenge')
      end
      # Stale packets can still be queued by a transport callback. Native
      # match checks must discard them even though the rally is again zero.
      packet = old_channels['alice'].event_sent.first
      assert(packet, 'No real native event was produced by the first point')
      h.network['host'].event_inbox << ['alice', JSON.parse(packet)]
      h.network['host'].inbox['alice'] = JSON.parse(old_channels['alice'].sent.last)
      h.advance(20)
      assert_equal(nil, h.wrappers['Host'].context_data['duck_realtime_point'])
      second = h.complete_native_point
      assert_equal(2, second['id'])
      assert_equal(receipt['participants'], second['participants'])
      h.wrappers.each_value { |wrapper| assert(wrapper.finish_point(second)) }
      h.advance(20)
      old_clients.each_value { |client| assert_equal(true, client.instance_variable_get(:@closed)) }
      assert_equal(8, h.created.length)
      h.wrappers.each do |name, wrapper|
        assert_equal(false, wrapper.before_wait(h.parent, name), 'Finished second challenge restarted')
        assert_equal(1, h.audios[name].calls.count { |call| call.first == :close })
      end
    ensure
      h.close
    end
  end

  def controller_changes(kind)
    h = DuckRealtimeHarness.new(kind: kind)
    begin
      h.advance(40)
      clients = h.wrappers.transform_values(&:native_client)
      previous = clients.transform_values { |client| client.instance_variable_get(:@match) }
      # A transient disconnected channel is not a departure/cancellation.
      h.network['alice'].connected = false
      h.advance(300)
      h.wrappers.each do |name, wrapper|
        assert(wrapper.active?)
        assert_equal(clients[name], wrapper.native_client)
        assert_equal(nil, wrapper.context_data['duck_realtime_point'])
      end
      h.network['alice'].connected = true
      h.session['__control_epoch'] = 'new-owner'
      h.session['__table_owner'] = 'Watcher'
      h.owner = 'Watcher'
      h.wrappers.each do |name, wrapper|
        wrapper.update_table_control(h.session)
        assert_equal(name == 'Watcher', wrapper.host?)
        assert(previous[name] != wrapper.native_client.instance_variable_get(:@match))
        assert_equal(%w[Alice Bob], wrapper.native_client.instance_variable_get(:@initial_players))
        assert_equal('Watcher', wrapper.projection.replay.state[:owner])
        assert_equal(wrapper.projection.first_server, wrapper.native_client.engine.server)
      end
      receipt = h.complete_native_point
      assert_equal('new-owner', receipt['epoch'])
      assert_equal(nil, h.wrappers['Host'].context_data['duck_realtime_point'])
      assert_equal(receipt, h.wrappers['Watcher'].context_data['duck_realtime_point'])
      # Replacing one selected seat cancels, rather than repeating the point
      # under the same channel identity with a different controller.
      h.session['__players'][1] = GameRoomParticipants.bot_id(20, 1)
      h.session['__control_epoch'] = 'new-player'
      h.wrappers.each do |name, wrapper|
        wrapper.update_table_control(h.session)
        assert_equal(false, wrapper.active?)
        assert_equal(nil, wrapper.native_client)
        assert_equal(false, wrapper.finish_point(receipt))
        assert_equal(false, wrapper.before_wait(h.parent, name), 'Stale projection resurrected cancelled challenge')
      end
      h.parent.players = h.session['__players'].dup
      h.wrappers.each do |name, wrapper|
        assert_equal(false, wrapper.before_wait(h.parent, name), 'Replacement replay started the old challenge')
      end
    ensure
      h.close
    end

    h = DuckRealtimeHarness.new(kind: kind)
    begin
      children = h.wrappers.transform_values(&:native_client)
      # An unrelated racer's departure leaves the pair intact.
      h.session['__players'][3] = GameRoomParticipants.bot_id(20, 2)
      h.session['__control_epoch'] = 'unrelated-player'
      h.wrappers.each do |name, wrapper|
        wrapper.update_table_control(h.session)
        assert(wrapper.active?)
        assert_equal(children[name], wrapper.native_client)
      end
      h.parent.state[:race][:challenge] = nil
      h.wrappers.each do |name, wrapper|
        assert_equal(false, wrapper.before_wait(h.parent, name))
        assert_equal(nil, wrapper.native_client)
        assert_equal(true, children[name].instance_variable_get(:@closed))
      end
    ensure
      h.close
    end
  end

  def human_and_bot(kind)
    bot = GameRoomParticipants.bot_id(20, 1)
    2.times do |server|
      seed = (0..100).find { |value| Random.new(value).rand(2) == server }
      h = DuckRealtimeHarness.new(kind: kind, racers: ['Host', 'Alice', bot, 'Watcher'], seed: seed)
      begin
        h.wrappers.each do |name, wrapper|
          child = wrapper.native_client
          assert_equal(server, child.engine.server)
          assert_equal(name == 'Host' ? 1 : 0, child.instance_variable_get(:@bots).length)
        end
        h.advance(180)
        if server == 1
          assert(h.wrappers['Host'].native_client.engine.turn.positive?, 'Selected bot did not actually serve')
          assert(!h.activity.empty?)
        else
          assert_equal(0, h.wrappers['Host'].native_client.engine.turn, 'Human first serve was replaced by bot-first rule')
        end
      ensure
        h.close
      end
    end
  end

  def invalid_projection(kind)
    h = DuckRealtimeHarness.new(kind: kind)
    begin
      base = h.parent.state[:race][:challenge]
      [base.merge(id: 0), base.merge(seed: '1'), base.merge(participants: [1, 1]),
        base.merge(participants: [1, 9]), base.merge(participants: [1, 2, 3])].each do |bad|
        assert_raises(ArgumentError) do
          GameRoomDuckRacing::RealtimeProjection.new(bad, h.parent.players, owner: 'Host')
        end
      end
      projection = GameRoomDuckRacing::RealtimeProjection.new(base, h.parent.players, owner: 'Host')
      base[:participants][0] = 3
      h.parent.players[1].replace('Changed')
      assert_equal([1, 2], projection.participants)
      assert_equal(%w[Alice Bob], projection.players)
      assert_equal('duck:1', projection.match_scope)
      h.wrappers.each do |name, wrapper|
        assert_equal(false, wrapper.before_wait(h.parent, name), 'Changed identity restarted under the old scope')
      end
    ensure
      h.close
    end
  end

  def timeout_point(kind)
    h = DuckRealtimeHarness.new(kind: kind)
    begin
      h.advance(40)
      initial = h.wrappers.transform_values(&:projection)
      h.wrappers.each do |name, wrapper|
        assert(wrapper.before_wait(h.parent, name))
        assert_equal(initial[name].object_id, wrapper.projection.object_id, 'Unchanged view rebuilt native game/options')
      end
      receiver = 1 - initial.values.first.first_server
      name = initial.values.first.players.fetch(receiver)
      child = h.wrappers[name].native_client
      if kind == 'axel_pong'
        assert(child.request_hurry)
        assert_equal(false, h.wrappers['Host'].native_client.request_hurry)
      else
        assert(h.surfaces[name].on_audio_ball_command.call('hurry'))
        assert_equal(false, h.surfaces['Host'].on_audio_ball_command.call('hurry'))
      end
      h.advance(650)
      receipt = h.wrappers['Host'].context_data['duck_realtime_point']
      assert_equal("0:#{receiver}:timeout", receipt&.[]('point'))
      assert_equal(initial.values.first.participants.fetch(receiver), receipt['winner'])
      h.wrappers.each_value { |wrapper| assert(wrapper.finish_point(receipt)) }
    ensure
      h.close
    end
  end
end

DuckRealtimeLifecycleTest.new.run
