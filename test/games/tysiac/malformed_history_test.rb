require_relative "../../support/tysiac_two_player"
require_relative "../../support/native_room_harness"

fixture = TwoPlayerTysiacFixture.new
h = NativeRoomHarness.new(game: fixture.game, users: fixture.players,
  options: JSON.parse(fixture.session.fetch('options')))
h.start
h.submit('Alice', {'kind'=>'command', 'action'=>'deal'}, context:context_for)
assert(h.events('Alice').first['__server_random'], 'The native prefix did not use server random')
h.submit(h.replay('Alice').current_player, {'kind'=>'command', 'action'=>'bid', 'bid'=>100})
h.submit(h.replay('Alice').current_player, {'kind'=>'command', 'action'=>'bid', 'bid'=>'pass'})
h.submit(h.replay('Alice').current_player,
  {'kind'=>'question', 'action'=>'submit', 'question_id'=>'choose_talon', 'answer'=>'0'})
3.times do
  replay = h.replay('Alice')
  actor = replay.current_player
  h.submit(actor, {'kind'=>'card', 'action'=>'select', 'card'=>replay.state[:hands][actor].first})
end
h.submit(h.replay('Alice').current_player, {'kind'=>'command', 'action'=>'contract', 'bid'=>100})
before = h.replay('Alice')
assert(before.state[:phase] == :playing, 'Legal prefix did not reach play')
['normal|XX', 'normal', 'normal|', '|', '', 'invalid|AS', 'normal|AS|extra'].each do |value|
  h.write(before.current_player, [GameRoomGames::EventCommand.new(action: 'play', value: value)])
  h.users.each do |user|
    replay = h.replay(user)
    assert(replay.state == before.state && replay.accepted_events == before.accepted_events, "Malformed command changed state: #{value}")
  end
end
action = h.game.legal_actions(before, before.current_player).first
h.submit(before.current_player, action)
h.assert_converged('Next legal move after malformed history')
assert(h.replay('Alice').accepted_events.length == before.accepted_events.length + 1, 'Malformed entries blocked subsequent legal play')
puts 'PASS Tysiac: malformed participant records ignored without mutation; two clients converge on next legal move'
