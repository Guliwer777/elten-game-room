require_relative '../support/session_runner'
require_relative '../../games/cat_head_tail'

# The native API authenticates the draw, not its participant-supplied context.
# Exercise both callback delivery and a cold stack read, then a legitimate
# server draw. A malformed wrapper must not poison the remaining history.
invalid_data = [nil, true, false, 0, 1.5, [], ['data'], 'wrong']
[:callback, :read].each do |delivery|
  h = NativeRoomHarness.new(game: GameRoomGames::CatHeadTail.new, users: %w[Alice Bob])
  h.start
  h.broker.automatic_delivery = false
  invalid_data.each do |data|
    h.view('Bob').stack_push_random(min: 1, max: 6, count: 1,
      context: {'kind'=>'game_action', 'data'=>data}, message_id: SecureRandom.uuid)
  end
  invalid_data.each do |request|
    h.view('Bob').stack_push_random(min: 1, max: 6, count: 1,
      context: {'kind'=>'game_action', 'data'=>{'random_request'=>request}}, message_id: SecureRandom.uuid)
  end
  h.broker.deliver(duplicate: true) if delivery == :callback
  h.users.each do |user|
    snapshot = h.repositories[user].snapshot_for(h.session, force_events: true)
    assert(snapshot.events.empty?, "#{delivery}: malformed native random entry became a game event")
  end
  h.broker.automatic_delivery = true
  h.view('Alice').next_random_values = Array.new(16, 4)
  context = GameRoomGames::ActionContext.new(random_source: GameRoomRandom::LocalSecureSource.new)
  h.submit('Alice', {'kind'=>'command', 'action'=>'roll'}, context: context)
  h.assert_converged("#{delivery}: malformed random context recovery", expected_count: 1)
  h.users.each do |user|
    assert(h.replay(user).accepted_events.one?, "#{delivery}: later valid draw was blocked")
  end
end
puts 'PASS malformed authenticated random contexts: callbacks, cold reads and later legitimate server draw'
