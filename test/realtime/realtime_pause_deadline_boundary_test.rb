require_relative '../support/audio_ball_client'

module RealtimePauseDeadlineContract
  module_function

  def control(h, paused, epoch: 'initial', owner: 'Alice')
    h.clients.each_value do |client|
      client.update_table_control('__frozen' => paused, '__control_epoch' => epoch, '__table_owner' => owner)
    end
  end

  def ready_times(h)
    h.clients.transform_values { |client| client.send(:rally_state).ready_at }
  end

  def agreed_point(h)
    if h.is_a?(AudioBallHarness)
      h.win_point('Alice', persist: false)
      h.clients.fetch('Alice').context_data.fetch('audio_ball_point')
    else
      h.press(h.players.fetch(h.clients.fetch('Alice').engine.server))
      1000.times do
        h.advance(1)
        value = h.clients.fetch('Alice').context_data['pong_point']
        return value if value
      end
      raise 'Pong fixture never reached an agreed point'
    end
  end

  def accept_point(h, value)
    return h.commit if h.is_a?(AudioBallHarness)
    before = h.replay
    h.accept_point(value)
    event = h.instance_variable_get(:@events).last
    h.clients.each { |viewer, client| client.event(event, before, h.replay, viewer, h.repository) }
  end
end

failures, evidence = [], []
[PongHarness, AudioBallHarness].each do |type|
  h = type.new
  begin
    h.advance(300)
    value = RealtimePauseDeadlineContract.agreed_point(h)
    RealtimePauseDeadlineContract.control(h, true)
    h.advance(500)
    # The result was already agreed before freezing; its accepted durable
    # event reaches the UI after eight seconds of that pause.
    RealtimePauseDeadlineContract.accept_point(h, value)
    created_at = h.now
    created = RealtimePauseDeadlineContract.ready_times(h)
    h.advance(125)
    resumed_at = h.now
    RealtimePauseDeadlineContract.control(h, false)
    actual = RealtimePauseDeadlineContract.ready_times(h)
    expected = created.transform_values { |deadline| deadline + resumed_at - created_at }
    evidence << {case: "#{type}: durable point delivered during pause", created_at: created_at,
      resumed_at: resumed_at, expected: expected, actual: actual}
    actual.each do |viewer, deadline|
      failures << "#{type}/#{viewer}: late point counted pause time from before its deadline existed" unless
        (deadline - expected.fetch(viewer)).abs < 0.00001
    end
  ensure
    h.close
  end
end

# An authenticated host/control epoch can reset the rally while everyone is
# paused. The newly created readiness deadline must not inherit eight earlier
# paused seconds from the previous engine.
h = AudioBallHarness.new
begin
  h.advance(300)
  RealtimePauseDeadlineContract.control(h, true)
  h.advance(500)
  RealtimePauseDeadlineContract.control(h, true, epoch: 'handover-during-pause', owner: 'Bob')
  h.clients.each { |viewer, client| client.before_wait(h.replay, viewer) }
  # Let the new channel epoch initialize, as the normal frame loop does.
  h.advance(1)
  created_at = h.now
  created = RealtimePauseDeadlineContract.ready_times(h)
  h.advance(125)
  resumed_at = h.now
  RealtimePauseDeadlineContract.control(h, false, epoch: 'handover-during-pause', owner: 'Bob')
  actual = RealtimePauseDeadlineContract.ready_times(h)
  expected = created.transform_values { |deadline| deadline + resumed_at - created_at }
  evidence << {case: 'AudioBall host change during pause', expected: expected, actual: actual}
  actual.each do |viewer, deadline|
    failures << "AudioBall/#{viewer}: new host readiness inherited time before the epoch change" unless
      (deadline - expected.fetch(viewer)).abs < 0.00001
  end
ensure
  h.close
end

puts JSON.pretty_generate(evidence)
raise failures.join("\n") unless failures.empty?
puts 'PASS realtime deadlines created during pause: accepted point and host/epoch reset use only their own paused interval'
