require_relative '../support/private_card_games'

game = GameRoomGames::Uno.new
h, runners = PrivateCardGamesTest.create(game, users:%w[Alice Bob Carol], options:{'thinking_time'=>20},
  random_values:Array.new(16,8))
80.times do
  break unless game.send(:private_waiting?, h.replay('Alice').state)
  PrivateCardGamesTest.tick(h,runners)
end
actor = h.replay('Alice').current_player
assert(actor != 'Alice', 'Fixture must time out a player other than the first seat')
replay = h.replay(actor)
deadline = replay.state[:turn_deadline]
ctx = GameRoomGames::ActionContext.new(now:deadline+1, table_owner:'Alice', server_random:true)
early = GameRoomGames::ActionContext.new(now:deadline-1, table_owner:'Alice', server_random:true)
assert(!game.automatic_action_due?(replay,actor,context:early), 'Early timeout')
assert(game.automatic_action_due?(replay,actor,context:ctx), 'The current account cannot perform its timeout')
assert(!game.automatic_action_due?(h.replay('Alice'),'Alice',context:ctx), 'Owner claims another account timeout')
selection = game.automatic_action(replay,actor,context:ctx)
assert(selection && selection['action'] == 'turn_timeout', 'Timeout action missing')
before = replay.state[:hands][actor].size
h.submit(actor,selection,context:ctx)
80.times do
  PrivateCardGamesTest.tick(h,runners)
  break unless game.send(:private_waiting?,h.replay(actor).state)
end
after = h.replay(actor)
assert(after.state[:hands][actor].size == before+1 && after.current_player != actor, 'Timeout did not draw and advance')
assert(after.history.any? { |entry| entry.key.start_with?('timeout:') }, 'Timeout history missing')
PrivateCardGamesTest.assert_private(h)
runners.each_value(&:close)
puts 'PASS private UNO timeout: current account draws, owner cannot read it, ordinary turn advances'
