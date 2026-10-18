require_relative '../support/private_card_games'
require_relative '../../lib/private_card_ledger'

ledger = GameRoomPrivateCardLedger
state = {private_public: ['C'], private_draws: {'draw' => {pool: 'pool', player: 'Alice', count: 2, used: []}},
  private_pools: {'pool' => {cards: %w[A B C]}}}
event = {'__server_pool' => {'operation'=>'reveal', 'draw_id'=>'draw', 'pool_id'=>'pool', 'values'=>[2]}}
hand = ['C', 'hidden:draw:1', 'hidden:draw:0']
previous = Marshal.dump([state, hand])
assert(!ledger.with_cards(state, event, 'Bob', hand: hand, cards: %w[C B], positions: [0,1]) { true }, 'foreign proof accepted')
assert(Marshal.dump([state, hand]) == previous, 'foreign proof changed packet')
assert(!ledger.with_cards(state, event, 'Alice', hand: hand, cards: %w[C B], positions: [1,0]) { true }, 'wrong public position accepted')
assert(!ledger.with_cards(state, event, 'Alice', hand: hand, cards: %w[C B], positions: [0,0]) { true }, 'duplicate slot accepted')
assert(!ledger.with_cards(state, event, 'Alice', hand: hand, cards: %w[C B], positions: [0,1]) { false }, 'rejected move committed')
assert(Marshal.dump([state, hand]) == previous, 'rejected move consumed or reordered packet')
assert(ledger.with_cards(state, event, 'Alice', hand: hand, cards: %w[C B], positions: [0,1]) {
  assert(hand == ['C', 'B', 'hidden:draw:0'], 'private card materialized in wrong slot')
  hand.shift(2)
  true
}, 'mixed packet rejected')
assert(hand == ['hidden:draw:0'] && state[:private_draws]['draw'][:used] == [2], 'wrong proof consumption')
assert(!ledger.with_cards(state, event, 'Alice', hand: hand, cards: ['B']) { true }, 'spent proof reused')
assert(ledger.with_cards(state, {}, 'Alice', hand: ['C'], cards: ['C'], positions: [0]) { true }, 'public card cannot be played')
assert(!ledger.with_cards(state, event, 'Alice', hand: ['C'], cards: ['C'], positions: [0]) { true }, 'unrelated proof accepted')
# Atomic rule applicators may commit a copied model. Consume the receipt in
# that committed model, not in the discarded hash retained by this method.
copy = {private_public: [], private_draws: {'draw'=>{pool:'pool', player:'Alice', count:2, used:[]}},
  private_pools: {'pool'=>{cards:%w[A B]}}}
assert(ledger.with_cards(copy, event, 'Alice', hand:['hidden:draw:0', 'hidden:draw:1'], cards:['B']) {
  copy.replace(Marshal.load(Marshal.dump(copy)))
  true
}, 'copied model rejected')
assert(copy[:private_draws]['draw'][:used] == [2], 'receipt consumed only in discarded model')
puts 'PASS shared card packets: positions, mixed public/private cards, rollback and spent/foreign proofs'
