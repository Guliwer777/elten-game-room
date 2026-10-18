require_relative '../support/private_card_games'

ids = ['12345678-1234-1234-1234-123456789012', 'abcdefab-abcd-abcd-abcd-abcdefabcdef']
pool_cards = (1..1000).map { |number| "card-#{number}" }
draw_values = {ids[0] => (91..100).to_a, ids[1] => (991..1000).to_a}
own_cards = draw_values.values.flatten.map { |value| pool_cards.fetch(value - 1) }
selected = own_cards.values_at(0, 1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 15)
state = {phase: :playing, current_player: 'Alice', private_viewer: 'Alice', private_public: [],
  private_values: draw_values, private_known: {ids[0] => (91..100).to_a, ids[1] => (991..993).to_a},
  private_draws: draw_values.to_h { |id, values| [id, {pool:'pool', player:'Alice', count:values.size, used:[]}] },
  private_pools: {'pool' => {cards: pool_cards}}, hands: {'Alice' => own_cards.dup}}
GameRoomPrivateCardDisclosure.prepare(state, ['Alice'], purpose: 'action', cards: {'Alice' => selected})
claims = reveals = 0
until GameRoomPrivateCardDisclosure.complete?(state)
  before = Marshal.dump(state)
  command = GameRoomPrivateCardDisclosure.command(state, 'Alice')
  assert(Marshal.dump(state) == before, 'planning a bounded disclosure mutated its source')
  GameRoomEventProtocol.validate_commands!([command])
  request = command.pool_request
  if request.fetch('operation') == 'claim'
    claims += 1
    event = {'action' => 'private_show', 'value' => command.value}
  else
    reveals += 1
    values = GameRoomPrivateCards.reveal_values(request)
    event = {'action'=>'private_show', 'value'=>command.value,
      '__server_pool'=>{'operation'=>'reveal', 'pool_id'=>request.fetch('pool_id'),
        'draw_id'=>request.fetch('draw_id'), 'values'=>values}}
  end
  assert(!GameRoomPrivateCardDisclosure.apply(state, event, 'Bob'), 'foreign account reused receipt')
  assert(GameRoomPrivateCardDisclosure.apply(state, event, 'Alice'), 'bounded mixed receipt failed')
  assert(!GameRoomPrivateCardDisclosure.apply(state, event, 'Alice'), 'duplicate claim spent selected cards twice')
  assert((state[:private_public] - selected).empty?, 'disclosed an unselected part of the hand')
  assert(state[:hands]['Alice'] == own_cards, 'disclosure changed card positions')
  assert(claims + reveals <= selected.size, 'bounded disclosure stopped making progress')
end
assert(claims >= 2 && reveals == 1, 'mixed public/private receipts were not exercised')
assert(state[:private_public].sort == selected.sort, 'selected disclosure incomplete')
assert(state[:private_draws].values.sum { |draw| draw[:used].size } == selected.size, 'receipt consumption crossed selected boundary')
puts 'PASS independent disclosure scope: mixed receipts, known/unknown values, bounded claims, no extra cards, no planning mutation and one-time use'
