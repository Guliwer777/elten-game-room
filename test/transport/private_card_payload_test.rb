require_relative '../support/private_card_games'
require_relative '../../games/rummy'

# Use the real decoder and ledger, but a tiny applicator to isolate the
# transaction boundary from Rummy's combinations and scoring.
class PrivatePayloadBoundary
  def id; 'rummy'; end
  def apply_replay_event(state, event, _session, _repository, history)
    return false unless event.dig('__payload', 'valid')
    cards = event.dig('__payload', 'cards')
    return false unless (cards - state[:hands]['Alice']).empty?
    state[:hands]['Alice'] -= cards
    state[:played] = cards
    history << GameRoomGames::HistoryEntry.new(key:'applied', event_id:1)
    true
  end
  def same_user?(first, second); first.to_s.casecmp?(second.to_s); end
  def hand_for(state, actor); state[:hands][actor]; end
  def copy_state(state); Marshal.load(Marshal.dump(state)); end
end
module PrivatePayloadAdapter
  include GameRoomPrivateCardPayload
  def private_payload_cards(data, _state); data['cards']; end
end
PrivatePayloadBoundary.prepend(PrivatePayloadAdapter)
game = PrivatePayloadBoundary.new
repository = Object.new
def repository.actor_of(event, _session); event.fetch('actor'); end
def repository.event_id(event); event.fetch('id', 2); end
state = {private_cards: true, private_public: ['C'], private_values: {},
  private_draws: {'one'=>{pool:'pool', player:'Alice', count:1, used:[]},
                 'two'=>{pool:'pool', player:'Alice', count:1, used:[]}},
  private_pools: {'pool'=>{cards:%w[A B C]}},
  hands: {'Alice'=>['hidden:one:0', 'hidden:two:0', 'C']},
  phase: :playing, current_player:'Alice', round:1, turn:1}
move = {'actor'=>'Alice', 'action'=>'meld', '__payload'=>{
  'valid'=>true, 'cards'=>%w[A B C], 'round'=>1, 'turn'=>1}}
history = []
assert(game.send(:apply_replay_event, state, move, {}, repository, history), 'payload not staged')
assert(state[:phase] == :private_show && history.empty? && !state[:played], 'partial move applied')
proof = ->(draw, value, actor = 'Alice') { {'actor'=>actor, 'action'=>'private_show', 'value'=>'action',
  '__server_pool'=>{'operation'=>'reveal', 'pool_id'=>'pool', 'draw_id'=>draw, 'values'=>[value]}} }
before = Marshal.dump(state)
assert(!game.send(:apply_replay_event, state, proof.call('one', 1, 'Bob'), {}, repository, history), 'foreign account proof accepted')
assert(Marshal.dump(state) == before, 'foreign proof changed state')
assert(!game.send(:apply_replay_event, state, proof.call('one', 3), {}, repository, history), 'unselected card accepted')
assert(game.send(:apply_replay_event, state, proof.call('one', 1), {}, repository, history), 'first receipt rejected')
assert(history.empty? && !state[:played] && state[:phase] == :private_show, 'partial receipt applied meld')
assert(game.send(:apply_replay_event, state, proof.call('two', 2), {}, repository, history), 'second receipt rejected')
assert(history.map(&:key) == ['applied'] && history.first.event_id == 2 && state[:played] == %w[A B C] && state[:hands]['Alice'].empty?, 'complete move not presented once at its receipt')
assert(!game.send(:apply_replay_event, state, proof.call('two', 2), {}, repository, history), 'duplicate disclosure accepted')

commands = GameRoomActionPayload.commands('rummy', {'action'=>'meld', 'groups'=>[Array.new(40) { |i| "card#{i}" }]})
assert(commands.size > 1, 'fixture does not fragment')
valid = ->(rows) { GameRoomPrivateCards.valid_commands?('rummy', rows.map { |row| GameRoomEventProtocol.normalized(row) },
  controlled:false, host:false, pool:nil, random:false) }
assert(valid.call(commands), 'complete payload rejected')
assert(!valid.call(commands[0...-1]), 'partial payload accepted')
assert(!valid.call(commands.reverse), 'reordered payload accepted')
claims = commands.map { |row| GameRoomPrivateCards.command(row.action, row.value, operation:'claim') }
assert(GameRoomPrivateCards.request_from(claims) == {'operation'=>'claim'}, 'claims not one transaction')

rummy = GameRoomGames::Rummy.new
h, runners = PrivateCardGamesTest.create(rummy, users:%w[Alice Bob], options:{'thinking_time'=>20})
actor = h.replay('Alice').current_player
replay = h.replay(actor)
context = GameRoomGames::ActionContext.new(now:replay.state[:turn_deadline], table_owner:'Alice')
assert(rummy.automatic_action_due?(replay, actor, context:context), 'private turn timer not due')
assert(rummy.automatic_action(replay, actor, context:context)['action'] == 'timeout', 'private timeout missing')
other = (%w[Alice Bob] - [actor]).first
assert(!rummy.automatic_action_due?(h.replay(other), other, context:context), 'foreign timer active')
assert(rummy.automatic_action(h.replay(other), other, context:context).nil?, 'foreign timeout scheduled')
assert(rummy.surface_spec(replay, actor).is_a?(GameSurfaces::MeldHandSpec), 'ordinary meld surface lost')
runners.each_value(&:close)
puts 'PASS private payloads: atomic fragments, multiple receipts, foreign/duplicate proofs, timers and normal meld surface'
