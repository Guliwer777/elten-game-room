require_relative 'realtime_helpers'

class DuckRealtimeClientTest
  include GameRoomTest::Assertions
  def assert(value, message = 'Assertion failed')
    @checks = (@checks || 0) + 1
    super
  end

  def run
    %w[axel_pong audio_ball].each do |kind|
      harness = DuckRealtimeHarness.new(kind: kind)
      begin
        original = Marshal.dump(harness.parent)
        clients = harness.wrappers
        assert_equal(4, clients.length)
        clients.each do |name, wrapper|
          projection, child = wrapper.projection, wrapper.native_client
          assert_equal(%w[Alice Bob], projection.players)
          assert_equal([1, 2], projection.participants)
          assert_equal('duck:1', projection.match_scope)
          assert_equal(kind == 'axel_pong' ? 2 : 3, projection.replay.state[:options]['difficulty'])
          assert_equal(false, projection.replay.state[:options]['arcade']) if kind == 'axel_pong'
          assert_equal([0, 0], projection.replay.state[:scores])
          assert_equal(20, child.instance_variable_get(:@activity_table))
          assert_equal(300, child.instance_variable_get(:@activity_session))
          assert_equal(%w[Alice Bob], child.instance_variable_get(:@initial_players))
          expected = %w[Alice Bob].index(name)
          assert_equal(expected, child.instance_variable_get(:@side))
          assert_equal(name == 'Host', child.host?)
          assert_equal(projection.first_server, child.engine.server)
          assert_equal(nil, wrapper.context_data['duck_realtime_point'])
          assert_equal(kind, projection.surface_spec(name).game_id)
          assert(!projection.shortcuts(name).empty?)
        end
        assert_equal(1, clients.values.map { |wrapper| wrapper.native_client.instance_variable_get(:@match) }.uniq.length)
        assert_equal(Marshal.dump(harness.parent), original, 'Local projection changed parent state')
        $spoken_messages.clear
        receipt = harness.complete_native_point
        assert_equal(1, receipt['id'])
        assert_equal(kind, receipt['kind'])
        assert_equal([1, 2], receipt['participants'])
        assert([1, 2].include?(receipt['winner']))
        assert_equal('initial', receipt['epoch'])
        assert(!harness.activity.empty?)
        assert(harness.activity.all? { |entry| entry == [20, 300] })
        assert(!$spoken_messages.any? { |text| text.include?('points to win') }, 'Nested Pong announced a full match')
        assert(harness.audios.values.none? { |audio| audio.calls.any? { |call| call.first == :set } }, 'Nested Ball announced a set')
        clients.each do |name, wrapper|
          assert_equal(name == 'Host' ? receipt : nil, wrapper.context_data['duck_realtime_point'])
        end
        # Reconciliation may ask repeatedly. The offered receipt is stable,
        # and a caller cannot mutate the next offer by editing its copy.
        bad_copy = clients['Host'].context_data['duck_realtime_point']
        bad_copy['participants'][0] = 99
        bad_copy['point'].replace('0:9')
        assert_equal(receipt, clients['Host'].context_data['duck_realtime_point'])
        clients['Host'].automatic_error(:network_error)
        assert_equal(receipt, clients['Host'].context_data['duck_realtime_point'])
        turns = clients.transform_values { |wrapper| wrapper.native_client.engine.turn }
        harness.advance(80)
        assert_equal(turns, clients.transform_values { |wrapper| wrapper.native_client.engine.turn }, 'Second serve began before race acceptance')

        invalid = [receipt.merge('id' => 2), receipt.merge('epoch' => 'old'),
          receipt.merge('winner' => 0), receipt.merge('point' => '1:0'),
          receipt.merge('participants' => [2, 1])]
        invalid.each { |value| assert_equal(false, clients['Host'].finish_point(value)) }
        assert_equal(receipt, clients['Host'].context_data['duck_realtime_point'])
        clients.each_value do |wrapper|
          assert(wrapper.finish_point(receipt))
          assert_equal(false, wrapper.active?)
          assert_equal(false, wrapper.finish_point(receipt), 'Accepted point played twice')
          assert_equal(nil, wrapper.context_data['duck_realtime_point'])
          assert_equal(nil, wrapper.native_client.instance_variable_get(:@form))
          assert_equal(false, wrapper.native_client.instance_variable_get(:@channel).connected?)
        end
        assert(harness.audios.values.none? { |audio| audio.calls.any? { |call| call.first == :point } }, 'Challenge created a full-match result sequence')
        harness.advance(20)
        clients.each_value { |wrapper| assert_equal(nil, wrapper.native_client) }
        assert_equal(original, Marshal.dump(harness.parent), 'Wrapper persisted a native point instead of returning a receipt')
        clients.each do |name, wrapper|
          assert_equal(false, wrapper.before_wait(harness.parent, name), 'Accepted challenge restarted')
        end
        assert_equal(4, harness.created.length)
      ensure
        harness.close
      end
    end
    puts "PASS Duck native single-point clients: #{@checks} checks"
  end
end

DuckRealtimeClientTest.new.run
