require_relative '../support/private_card_games'
require_relative '../../games/ninety_nine'

game = GameRoomGames::NinetyNine.new
h, runners = PrivateCardGamesTest.create(game, users: Array.new(8) { |i| "Player#{i}" },
  options: {'starting_tokens'=>1000}, random_values: Array.new(16, 6))
# With the native pool fixture's deterministic shuffle, dealer 5 reaches
# recycling through legal minimum-total choices in the first round. A random
# first dealer can end several rounds before exhausting a single deck.
assert(h.replay(h.users.first).state[:dealer_index] == 5, 'wrong recycling fixture dealer')
recycled = false
500.times do
  rep = h.replay(h.users.first)
  break if rep.finished?
  if rep.state[:phase].to_s.start_with?('private_') || [:awaiting_deal, :round_complete].include?(rep.state[:phase])
    PrivateCardGamesTest.tick(h, runners)
    if h.events(h.users.first).any? { |event| event['action'] == 'private_recycle' }
      recycled = true
      break if h.replay(h.users.first).state[:phase] == :playing
    end
    next
  end
  actor = rep.current_player
  mine = h.replay(actor)
  # Keep the running total down to reach a natural exhaustion of the deck.
  selection = game.legal_actions(mine, actor).min_by do |action|
    card, mode = game.send(:parse_play_choice, action['card'])
    game.send(:total_after_card, mine.state[:total], card, mode)
  end
  PrivateCardGamesTest.submit(h, runners, actor, selection)
end
assert(recycled, 'legal trace did not exhaust the deck')
PrivateCardGamesTest.assert_private(h)
state = h.replay(h.users.first).state
assert(state[:recycle_count] > 0 && state[:phase] == :playing, 'recycle did not resume')
guest = h.users[1]
hand = h.replay(guest).state[:hands][guest].dup
runners[guest].close
h.view(guest).leave
h.add_client(guest)
assert(h.join(guest), 'return failed')
runners[guest] = runner_for(h, guest)
assert(h.replay(guest).state[:hands][guest] == hand, 'hand lost after recycle/return')
h.view(h.users.first).transfer_ownership(h.view(h.users.first).participants.find { |p| p.user == h.users.last })
PrivateCardGamesTest.tick(h, runners)
actor = h.replay(h.users.first).current_player
mine = h.replay(actor)
action = game.legal_actions(mine, actor).first
snapshot = h.repositories[actor].snapshot_for(h.session)
ctx = GameRoomGames::ActionContext.new(table_owner: h.users.last)
status, plan = game.action_for(action, mine, actor, context: ctx)
assert(status == :ok, 'post-handover plan failed')
h.instance_variable_set(:@session, snapshot.session)
h.broker.automatic_delivery = false
h.view(actor).fail_next_push = :after
assert_raises(EltenAPI::LiveSessions::TimeoutError) { h.write(actor, plan.events) }
h.transports[actor].reconcile(h.table['__id'])
h.broker.automatic_delivery = true
h.broker.deliver(duplicate: true)
PrivateCardGamesTest.tick(h, runners)
PrivateCardGamesTest.assert_private(h)
assert(h.replay(actor).accepted_events.size == h.events(actor).size, 'uncertain move lost')
runners.each_value(&:close)
puts 'PASS 99 private recycling, cold return, host transfer and uncertain reveal'
