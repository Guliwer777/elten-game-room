require_relative 'realtime_helpers'

include GameRoomTest::Assertions

%w[axel_pong audio_ball].each do |kind|
  harness = DuckRealtimeHarness.new(kind: kind)
  begin
    children = harness.wrappers.transform_values(&:native_client)
    received = {}
    children.each do |name, child|
      original = child.method(:update_table_control)
      child.define_singleton_method(:update_table_control) do |session|
        received[name] = session.dup
        original.call(session)
      end
    end
    [true, false, nil].each do |frozen|
      harness.session['__frozen'] = frozen
      harness.wrappers.each do |name, wrapper|
        wrapper.update_table_control(harness.session)
        control = received.fetch(name)
        assert_equal(frozen, control['__frozen'], 'Duck wrapper discarded the table pause state')
        assert_equal(%w[Alice Bob], control['__players'], 'Pause changed the challenge player projection')
        assert_equal('Host', control['__table_owner'], 'Pause changed the owner')
        assert_equal('initial', control['__control_epoch'], 'Pause invented a controller epoch')
        assert_equal(children[name], wrapper.native_client, 'Pause replaced the native game client')
      end
    end
  ensure
    harness.close
  end
end

puts 'PASS Duck realtime control projection preserves table pause, owner, epoch and participants'
