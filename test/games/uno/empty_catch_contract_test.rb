require_relative '../../support/new_games_fixture'
require_relative '../../../lib/game_event_protocol'

game = GameRoomGames::Uno.new
players = %w[Alice Bob Carol]
repository = NewGames116Repository.new(players)
session = {'options' => JSON.generate(game.default_options.merge('thinking_time' => 0))}
events = []
replay = game.replay(session, events, repository)
context = context_for
target = catcher = nil

# Reach the window by a real deal and legal actions, not by placing a
# one-card hand or UNO window directly into the model.
200.times do
  catcher = players.find { |actor| game.send(:catchable_player, replay.state, actor) }
  if catcher
    target = game.send(:catchable_player, replay.state, catcher)
    break
  end
  actor = replay.current_player || players.first
  action = game.automatic_action(replay, players.first, context: context)
  actor = players.first if action
  action ||= game.legal_actions(replay, actor).find { |value| !%w[uno catch].include?(value['action']) }
  assert(action, "No legal UNO progression at #{events.size}")
  replay = append_action(game, session, repository, events, replay, actor, action, context)
end
assert(target && replay.state[:hands][target].size == 1, 'No real catch window was reached')
assert(GameRoomEventProtocol.valid_wire_command?({'action' => 'catch', 'value' => ''}),
  'The empty-string boundary no longer reaches the game reducer')
before_state = Marshal.dump(replay.state)
before_history = replay.history.map(&:to_h)

['', 'Nobody|0'].each do |value|
  inserted = {'id' => events.size + 1, 'actor' => catcher, 'action' => 'catch', 'value' => value}
  rejected = game.replay(session, events + [inserted], repository)
  assert(rejected.accepted_events == replay.accepted_events, "UNO accepted invalid catch #{value.inspect}")
  assert(Marshal.dump(rejected.state) == before_state && rejected.history.map(&:to_h) == before_history,
    "Rejected catch #{value.inspect} changed the game")
  followup = inserted.merge('id' => inserted['id'] + 1, 'value' => "#{target}|0")
  recovered = game.replay(session, events + [inserted, followup], repository)
  assert(recovered.accepted_events.last == followup && recovered.state[:hands][target].size == 3,
    'A rejected catch prevented the next legitimate catch')
end

# Preserve both the current named-target packet and the existing explicit
# empty-target dialect. Only the malformed packet with no field is refused.
["#{target}|0", "#{target.downcase}|0", '|0'].each do |value|
  inserted = {'id' => events.size + 1, 'actor' => catcher, 'action' => 'catch', 'value' => value}
  accepted = game.replay(session, events + [inserted], repository)
  assert(accepted.accepted_events.last == inserted && accepted.state[:hands][target].size == 3,
    "UNO changed valid catch semantics for #{value.inspect}")
end
[target, 'Observer'].each do |actor|
  inserted = {'id' => events.size + 1, 'actor' => actor, 'action' => 'catch', 'value' => ''}
  rejected = game.replay(session, events + [inserted], repository)
  assert(rejected.accepted_events == replay.accepted_events && Marshal.dump(rejected.state) == before_state,
    'Empty catch changed self/observer authority')
end
puts 'PASS UNO: empty wire catch is harmless, real catch window survives and existing target dialects remain valid'
