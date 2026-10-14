require_relative 'client_helpers'

class DuckClientLifecycleTest
  include DuckClientTest

  def run
    if ENV['DUCK_MEMORY_ONLY'] == '1'
      sequential_queue
      final_memory_pair
      memory_tail_identity
      report('Duck client memory queue, final pair and lifetime')
      return
    end
    readiness_and_pulses
    if ENV['DUCK_SPEED_ONLY'] == '1'
      report('Duck speed preparation, finished trace and presence ordering')
      return
    end
    identity_and_controls
    sequential_queue
    final_memory_pair
    memory_tail_identity
    %w[axel_pong audio_ball].each { |kind| native_lifecycle(kind) }
    report('Duck client accepted actions, lifecycle, memory reveals and native goal tails')
  end

  def readiness_and_pulses
    setup_client('simon', phase: :preparing)
    assert_equal(nil, @client.instance_variable_get(:@trace))
    advance(29_999)
    assert_equal(nil, request)
    advance(30_000)
    assert_equal('alive', request['action'])
    original = Marshal.dump(request)
    5.times { assert_equal(original, Marshal.dump(@client.context_data['duck_action'])) }
    replace { |replay| replay.state[:round][:last_seen][1] = 130_000 }
    assert_equal(original, Marshal.dump(request), 'A foreign heartbeat acknowledged ours')
    replace { |replay| replay.state[:round][:last_seen][0] = 130_001 }
    assert_equal(nil, request)
    replace do |replay|
      round = replay.state[:round]
      round[:phase], round[:started_at] = :playing, 130_001
      round[:private] = GameRoomDuckRacing::PrivateRound.start(session_id: 91, round_id: '1',
        seats: [0, 1], started_at_ms: 130_001, reveal_timeout_ms: 90_000)
    end
    attach
    assert(@client.instance_variable_get(:@trace))
    assert_equal(30_000, @client.instance_variable_get(:@origin_ms))
    assert_equal(1, @game.loads, 'Entering playing reloaded dictionaries')
    advance(30_100)
    assert(@program.events.length.positive?)
    before = @surface.presents
    10.times { @client.frame }
    assert_equal(before, @surface.presents, 'Unchanged frame rewrote the accessible field')
    close

    setup_client('copy_number')
    finish_preparation
    @surface.push(:answer, value: @client.instance_variable_get(:@trace).state[:model][:answer])
    advance(5_000)
    queued = Marshal.dump(request)
    advance(30_000)
    assert_equal(queued, Marshal.dump(request), 'Presence overtook the finished result')
    assert_equal(nil, @client.instance_variable_get(:@pulse))
  ensure
    close
  end

  def identity_and_controls
    setup_client('guess_number')
    @surface.push(:answer, value: 50)
    advance(100)
    trace = @client.instance_variable_get(:@trace)
    old_replay = @replay
    replace { |replay| replay.state[:owner] = 'Bob' }
    assert_equal(false, @client.context_data['duck_host'])
    assert_equal(trace, @client.instance_variable_get(:@trace), 'Host transfer reset the attempt')
    assert_equal(false, @client.before_wait(old_replay, @viewer), 'A stale foreground replay replaced current state')
    assert_equal(trace, @client.instance_variable_get(:@trace))
    other_session = Marshal.load(Marshal.dump(@replay))
    other_session.state[:session_id] = 92
    assert_equal(false, @client.before_wait(other_session, @viewer))
    assert_equal(nil, @client.surface_spec(other_session, @viewer))
    assert_equal(nil, @client.surface_spec(@replay, 'Bob'))
    assert_equal([], @client.shortcuts(@replay, @viewer))
    replace do |replay|
      replay.state[:round][:challenge][:seed] += 1
      replay.state[:race][:challenge][:seed] += 1 unless replay.state[:race][:challenge].equal?(replay.state[:round][:challenge])
    end
    fresh = @client.instance_variable_get(:@trace)
    assert(!fresh.equal?(trace), 'A different draw reused the old attempt')
    assert_equal(2, @game.loads)
    @client.update_table_control({'__players' => %w[Alice Replacement Charlie], '__table_owner' => 'Bob'})
    assert_equal(nil, @client.instance_variable_get(:@trace))
    assert_equal(nil, request)
    assert_equal(false, @client.context_data['duck_ready'])
    replace { |replay| replay.players[1] = 'Replacement' }
    assert(@client.instance_variable_get(:@trace))
    assert(!fresh.equal?(@client.instance_variable_get(:@trace)))
    assert_equal(3, @game.loads)
    @client.close
    assert(@progress.closed)
    assert_equal({}, @client.context_data)
    assert_equal(nil, @client.surface_spec(@replay, @viewer))
    assert_equal([], @program.managed)
    @client.close
    assert_equal(1, @wrappers.last.calls.count { |call| call.first == :close })
  ensure
    close
  end

  def sequential_queue
    setup_client('sound_memory')
    turn = @replay.state[:round][:engine][:model][:public][:turn]
    if turn != 0
      close
      setup_client('sound_memory', viewer: 'Bob')
    end
    assert_equal(nil, @client.instance_variable_get(:@trace))
    @surface.push(:reveal, value: 1)
    @surface.push(:reveal, value: 2)
    advance(100)
    assert_equal(2, @client.instance_variable_get(:@inputs).length)
    assert_equal(1, request['input']['value'])
    assert_equal([], @program.events, 'An unaccepted reveal was audible')
    assert_equal(nil, @client.local_view.dig(:public, :sound_event))
    copies = Array.new(3) { @client.context_data['duck_action'] }
    copies.first['input']['value'] = 0
    assert_equal(1, request['input']['value'])
    replace { |replay| replay.state[:round][:last_seen][2] = 100_200 }
    assert_equal(1, request['input']['value'], 'Unrelated refresh removed an unsaved key')
    accepted1 = accept_input(request['input'], seat: turn, at: 200)
    assert_equal(2, request['input']['value'])
    accepted2 = accept_input(request['input'], seat: turn, at: 250)
    assert_equal(nil, request)
    # Both events arrive at the UI in the same refresh, just as when relay/
    # the ordinary writer was briefly busy. Each must be heard once.
    [accepted1, accepted2].each { |before, after, event| @client.event(event, before, after, @viewer, Repository.new) }
    [accepted1, accepted2].each { |before, after, event| @client.event(event, before, after, @viewer, Repository.new) }
    advance(260)
    advance(500)
    advance(750)
    assert_equal(3, @program.events.length)
    assert_equal(%w[replay buzzer].include?(@program.events.last[:asset]), true)
    assert_equal(false, @surface.presentation[:enabled])
    @surface.push(:reveal, value: 3)
    advance(800)
    assert_equal(nil, request, 'A third sound was accepted outside the player turn')
    assert_equal(1, @game.loads)
  ensure
    close
  end

  def final_memory_pair
    setup_client('sound_memory')
    model = @replay.state[:round][:engine][:model]
    pair = model[:private][:pairs].each_index.group_by { |index| model[:private][:pairs][index] }.values.first
    positions = pair.map { |index| index == 9 ? 0 : index + 1 }
    model[:public][:removed] = (0..9).to_a - positions
    model[:public][:sound_serial] = 8
    seat = model[:public][:turn]
    @client.before_wait(@replay, @viewer)
    first = accept_input({'kind' => 'reveal', 'value' => positions[0], 'press_id' => 1}, seat: seat, at: 100)
    second = accept_input({'kind' => 'reveal', 'value' => positions[1], 'press_id' => 2}, seat: seat, at: 200, complete: true)
    assert_equal(nil, @replay.state[:round])
    [first, second].each { |before, after, event| @client.event(event, before, after, @viewer, Repository.new) }
    advance(210)
    advance(500)
    advance(800)
    assert_equal(3, @program.events.length, 'The winning reveal/result was swallowed when the engine disappeared')
    assert_equal('replay', @program.events.last[:asset])
    assert_equal(@program.events[0][:frequency], @program.events[1][:frequency])
    assert_equal(nil, request)
  ensure
    close
  end

  def accept_input(input, seat:, at:, complete: false)
    before = Marshal.load(Marshal.dump(@replay))
    @program.now_ms = at
    @replay = Marshal.load(Marshal.dump(@replay))
    round = @replay.state[:round]
    assert(ENGINE.submit(round[:engine], seat: seat, action: input, now_ms: at, resources: resources))
    @replay.state[:revision] += 1
    round[:last_seen][seat] = 100_000 + at
    payload = {'action' => 'input', 'challenge' => round[:challenge][:id], 'input' => input, 'at' => 100_000 + at}
    commands = GameRoomActionPayload.commands('duck_racing', payload)
    commands.each do |command|
      @replay.accepted_events << {'action' => command.action, 'value' => command.value,
        '__id' => @replay.accepted_events.length + 1, 'actor' => @replay.players[seat]}
    end
    if complete
      assert(ENGINE.finished?(round[:engine]))
      @replay.state[:last_resolution] = {id: round[:challenge][:id], kind: 'sound_memory'}
      @replay.state[:race][:challenge] = @replay.state[:round] = nil
    end
    @client.before_wait(@replay, @viewer)
    [before, Marshal.load(Marshal.dump(@replay)), @replay.accepted_events.last]
  end

  def memory_tail_identity
    setup_client('sound_memory')
    seat = @replay.state[:round][:engine][:model][:public][:turn]
    before, after, event = accept_input({'kind' => 'reveal', 'value' => 1, 'press_id' => 1}, seat: seat, at: 100)
    @client.event(event, before, after, @viewer, Repository.new)
    next_replay = make_replay('copy_number', id: 2)
    next_replay.state[:revision] = @replay.state[:revision] + 1
    @replay = next_replay
    @client.before_wait(@replay, @viewer)
    assert_equal(nil, @client.instance_variable_get(:@trace), 'The next timed attempt overlapped the last reveal')
    @program.missing = true
    advance(110)
    assert_equal(nil, request, 'A failed old reveal cancelled the new challenge')
    assert(@client.instance_variable_get(:@trace), 'The failed old tail kept the new attempt blocked')
    @program.missing = false
    advance(120)
    assert_equal(nil, request)
    assert_equal(2, @game.loads)
    close

    setup_client('sound_memory')
    seat = @replay.state[:round][:engine][:model][:public][:turn]
    before, after, event = accept_input({'kind' => 'reveal', 'value' => 1, 'press_id' => 1}, seat: seat, at: 100)
    @client.event(event, before, after, @viewer, Repository.new)
    advance(110)
    assert_equal(1, @program.managed.length)
    replace do |replay|
      replay.state[:last_resolution] = {id: 1, cancelled: :participant_changed}
      replay.state[:round] = replay.state[:race][:challenge] = nil
    end
    assert_equal([], @program.managed, 'A cancelled memory round kept a sound alive')
    assert_equal(nil, request)
  ensure
    close
  end

  def native_lifecycle(kind)
    setup_client(kind, phase: :preparing, participants: [1, 2])
    wrapper = @wrappers.last
    assert_equal(false, !!wrapper.active?)
    assert_equal(nil, wrapper.projection)
    assert(@client.surface_spec(@replay, @viewer).view[:practice])
    assert_equal(false, @surface.presentation[:enabled], 'Spectator can confirm another player readiness')
    replace { |replay| replay.state[:round][:phase] = :playing; replay.state[:round][:started_at] = 100_000 }
    attach
    assert(wrapper.active?)
    assert_equal([1, 2], wrapper.projection.participants)
    assert_equal('Alice', wrapper.binding[:owner])
    assert_equal(91, wrapper.binding[:session_id])
    assert_equal(18, wrapper.binding[:table_id])
    assert(@client.surface_spec(@replay, @viewer))
    assert_equal(nil, @client.instance_variable_get(:@trace))
    receipt = {'id' => 1, 'kind' => kind, 'participants' => [1, 2], 'epoch' => 'initial', 'point' => '0:1', 'winner' => 2}
    wrapper.pending = receipt
    assert_equal(receipt, @client.context_data['duck_realtime_point'])
    replace do |replay|
      replay.state[:point_receipt] = receipt
      replay.state[:last_resolution] = {id: 1, kind: kind}
      replay.state[:round] = replay.state[:race][:challenge] = nil
    end
    assert(wrapper.finishing?)
    assert_equal(nil, @client.context_data['duck_realtime_point'])
    assert_equal(false, !!wrapper.closed)
    finish_index = wrapper.calls.index { |call| call.first == :finish }
    assert(wrapper.calls[(finish_index + 1)..].any? { |call| call == [:before_wait, nil] }, 'Challenge was cleared before its accepted point')
    advance(100)
    assert(wrapper.finishing?)
    next_replay = make_replay(kind, id: 2, participants: [1, 2])
    next_replay.state[:revision] = @replay.state[:revision] + 1
    @replay = next_replay
    @client.before_wait(@replay, @viewer)
    assert_equal(1, wrapper.projection.id, 'New challenge interrupted the goal tail')
    advance(200)
    assert(wrapper.active?)
    assert_equal(2, wrapper.projection.id)
    assert(@client.refresh_due?)
    assert_equal(false, @client.refresh_due?)
    replace do |replay|
      replay.state[:last_resolution] = {id: 2, kind: kind, cancelled: :participant_changed}
      replay.state[:round] = replay.state[:race][:challenge] = nil
    end
    assert(wrapper.closed, 'Cancelled match kept its controls/channel')
    assert_equal(2, @wrappers.length)
    assert_equal(nil, @client.context_data['duck_realtime_point'])
    assert_equal(nil, @client.surface_spec(@replay, @viewer))
    assert_equal([], @client.shortcuts(@replay, @viewer))
  ensure
    close
  end
end

DuckClientLifecycleTest.new.run
