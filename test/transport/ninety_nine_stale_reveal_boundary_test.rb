require_relative '../support/private_card_games'
require_relative '../../games/ninety_nine'

h, runners = PrivateCardGamesTest.create(GameRoomGames::NinetyNine.new,
  users: %w[Alice Bob], options: {'thinking_time'=>600})
begin
  actor = h.replay('Alice').current_player
  before = h.replay(actor)
  selection = h.game.legal_actions(before, actor).first
  card = selection.fetch('card').split('|').first
  receipt = GameRoomPrivateCardLedger.locate(before.state, actor, card)
  context = GameRoomGames::ActionContext.new(now:before.state[:turn_started], server_random:true)
  status, old_plan = h.game.action_for(selection, before, actor, context:context)
  assert(status == :ok, 'Could not capture a valid private card move')
  assert(old_plan.events.first.pool_request['operation'] == 'reveal', 'Initial play did not use a native reveal')

  # The host's timeout reaches the stack before the already prepared reveal.
  h.submit('Alice', {'kind'=>'command', 'action'=>'turn_timeout'},
    context:GameRoomGames::ActionContext.new(now:before.state[:turn_deadline]))
  after_timeout = h.replay(actor)
  assert(after_timeout.current_player != actor, 'Timeout did not advance the turn')
  h.write(actor, old_plan.events)
  after = h.replay(actor)
  assert(after.state[:hands][actor] == after_timeout.state[:hands][actor], 'Stale play removed a card')
  assert(after.state[:total] == after_timeout.state[:total], 'Stale play changed the total')
  assert(GameRoomPrivateCardLedger.known?(after.state, receipt),
    'A clock-rejected play lost its authenticated native reveal')
  assert(h.users.all? { |user| GameRoomPrivateCardLedger.known?(h.replay(user).state, receipt) },
    'Accounts disagree about irreversible public evidence')

  # Advance the other seat, then use the same physical card on a valid turn.
  h.submit('Alice', {'kind'=>'command', 'action'=>'turn_timeout'},
    context:GameRoomGames::ActionContext.new(now:after.state[:turn_deadline]))
  current = h.replay(actor)
  assert(current.current_player == actor, 'Did not return to the original seat')
  context.now = current.state[:turn_started]
  status, plan = h.game.action_for(selection, current, actor, context:context)
  assert(status == :ok && plan.events.first.pool_request['operation'] == 'claim',
    'A later legal play tries to reveal the already public receipt again')
  reveals = h.view(actor).calls[:reveal]
  h.write(actor, plan.events)
  assert(h.view(actor).calls[:reveal] == reveals, 'Repeated native reveal was sent')
  assert(!h.replay(actor).state[:hands][actor].include?(card), 'Known receipt did not play the card')
ensure
  runners.each_value(&:close)
end

puts 'PASS 99 late native reveal preserves evidence without accepting a stale clock or repeating the reveal'
