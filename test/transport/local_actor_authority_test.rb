require_relative '../support/native_room_harness'
require_relative '../../games/spades'
include GameRoomTest::Assertions

h = NativeRoomHarness.new(game: GameRoomGames::Spades.new)
h.start
assert_equal(nil, h.transports['Alice'].local_actor)
h.as('Alice') do
  begin
    h.repositories['Alice'].append_events(session: h.session, sequence: 0,
      events: [{'action' => 'deal', 'value' => '1|0|123'}], actor: 'Bob')
    raise 'Network repository accepted another player actor'
  rescue ArgumentError => error
    assert(error.message.include?('own move'), 'Wrong actor rejection')
  end
  begin
    h.transports['Alice'].append_game_action(session: h.session, sequence: 0,
      events: [{'action' => 'deal', 'value' => '1|0|123'}], actor: 'Bob')
    raise 'Network writer accepted another player actor'
  rescue ArgumentError => error
    assert(error.message.include?('control this seat'), 'Wrong writer rejection')
  end
end

# local_view is a lifecycle option, not identity: a regular SDK endpoint
# without the detached-local marker still needs the host's signed-in actor.
transport = GameRoomTransport.new(ProgramDouble.new(h.broker.endpoint('Alice')), local_view: true)
begin
  transport.start
  assert_equal(nil, transport.local_actor)
  h.as('Alice') do
    begin
      transport.append_game_action(session: h.session, sequence: 0,
        events: [{'action' => 'deal', 'value' => '1|0|123'}], actor: 'Bob')
      raise 'local_view bypassed network identity'
    rescue ArgumentError => error
      assert(error.message.include?('control this seat'), 'Wrong local_view actor rejection')
    end
  end
ensure
  transport.close_local_view
end
assert_equal([], h.events('Alice'))
puts 'PASS actor authority: ordinary network and unmarked local_view retain signed-in Session guards'
