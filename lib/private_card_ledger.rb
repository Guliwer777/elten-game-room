require_relative 'private_cards'

# Pure projection of the native pool receipts. It performs no I/O and knows
# nothing about turns, scoring, hand sizes or the meaning of a played card.
module GameRoomPrivateCardLedger
  module_function

  def initialize_state(state, session)
    state.merge!(private_cards: true, private_viewer: session['__private_viewer'],
      private_owner: session['__table_owner'], private_values: session.fetch('__private_draws', {}),
      private_ordered: GameRoomPrivateCards.ordered?(session['game']),
      private_pools: {}, private_draws: {}, private_known: {}, private_ready: [], private_initial: [], private_retired: [], private_public: [])
  end

  # A rejected interception cannot undo an irreversible native reveal. Keep
  # that evidence separately from accepted card use and hand positions.
  def observe_reveal(state, event, actor)
    proof = event['__server_pool']
    return unless proof && proof['operation'] == 'reveal'
    draw = state[:private_draws][proof['draw_id']]
    return unless draw && draw[:pool] == proof['pool_id'] && draw[:player].casecmp?(actor.to_s)
    values = proof['values']
    return unless GameRoomPrivateCards.valid_reveal_values?(values) && values.size <= draw[:count] &&
      values.all? { |value| value <= state[:private_pools].fetch(draw[:pool])[:cards].size }
    known = state[:private_known] ||= {}
    known[proof['draw_id']] = known.fetch(proof['draw_id'], []) | values
  end

  def known?(state, receipt)
    state.fetch(:private_known, {}).fetch(receipt[:draw_id], []).include?(receipt[:value])
  end

  def known_proof(state, actor, cards)
    state[:private_draws].each do |id, draw|
      next unless draw[:player].casecmp?(actor.to_s)
      pool_cards = state[:private_pools].fetch(draw[:pool])[:cards]
      values = state.fetch(:private_known, {}).fetch(id, []) - draw[:used]
      selected = values.select { |value| cards.include?(pool_cards[value - 1]) }
      next unless selected.size == cards.size
      return {'operation'=>'reveal', 'pool_id'=>draw[:pool], 'draw_id'=>id, 'values'=>selected}
    end
    nil
  end

  def retirable_pools(state, fresh: false)
    return [] if state[:private_ordered] && !fresh
    (state[:private_pools].keys - state[:private_retired]).select do |id|
      fresh || (state[:private_pools][id][:remaining].zero? &&
        state[:private_draws].values.none? { |draw| draw[:pool] == id && draw[:used].size < draw[:count] })
    end
  end

  def hidden?(card)
    card.is_a?(String) && card.start_with?('hidden:')
  end

  def locate(state, actor, card)
    state[:private_draws].each do |id, draw|
      next unless draw[:player].casecmp?(actor.to_s)
      cards = state[:private_pools].fetch(draw[:pool])[:cards]
      values = state[:private_values].fetch(id, []) - draw[:used]
      value = values.find { |index| cards[index - 1] == card }
      return {pool_id: draw[:pool], draw_id: id, value: value} if value
    end
    nil
  end

  def record_take(state, event, player, count:, public: false, pool_id: state[:private_pool])
    proof = event['__server_pool']
    return nil unless proof && proof['operation'] == 'take' && proof['pool_id'] == pool_id && state[:private_pools].key?(pool_id) &&
      proof['count'] == count && !state[:private_draws].key?(proof['draw_id']) &&
      (proof['visibility'] == 'public') == public
    pool = state[:private_pools].fetch(proof['pool_id'])
    unless proof['remaining'] == pool[:remaining] - count && proof['remaining'] >= 0
      state[:private_error] = :unexpected_draw
      return nil
    end
    state[:private_draws][proof['draw_id']] = {pool: proof['pool_id'], player: player, count: count, used: []}
    pool[:remaining] = proof['remaining']
    values = public ? proof['values'] : state[:private_values][proof['draw_id']]
    result = Array.new(count) do |index|
      value = values && values[index]
      card = value.is_a?(Integer) && value.between?(1, pool[:cards].size) ? pool[:cards][value - 1] : nil
      card || "hidden:#{proof['draw_id']}:#{index}"
    end
    if public
      state[:private_public] |= result
      state[:private_draws][proof['draw_id']][:used] = values.dup
    end
    result
  end

  # Make precisely the proved card available to the existing rule applicator.
  # A rejected move cannot consume its token. A native reveal still remains
  # public evidence, even if the game's rule rejects using it at that moment.
  def with_reveal(state, event, actor, hand:, card:)
    proof = event['__server_pool']
    return yield if !proof && state[:private_public].include?(card) && hand.include?(card)
    with_reveals(state, event, actor, hand: hand, cards: [card]) { yield }
  end

  # Played packets may contain previously public cards as well as private
  # cards from one receipt. Ordered games additionally bind the played slots.
  def with_cards(state, event, actor, hand:, cards:, positions: nil)
    return false if cards.empty? || cards.uniq.size != cards.size
    if positions
      return false unless positions.size == cards.size && positions.uniq.size == positions.size &&
        positions.all? { |position| position.is_a?(Integer) && position.between?(0, hand.size - 1) }
    end
    public_cards = cards & state[:private_public]
    return false unless public_cards.all? do |card|
      positions ? hand[positions[cards.index(card)]] == card : hand.include?(card)
    end
    private_cards = cards - public_cards
    return !event['__server_pool'] && yield if private_cards.empty?
    slots = positions && private_cards.map { |card| positions[cards.index(card)] }
    with_reveals(state, event, actor, hand: hand, cards: private_cards, positions: slots) { yield }
  end

  # One native receipt can disclose several cards from the same draw. This
  # is also used by end-of-hand scoring; each account supplies its own proof.
  def with_reveals(state, event, actor, hand:, cards:, positions: nil)
    proof = event['__server_pool'] || known_proof(state, actor, cards)
    return false unless proof && proof['operation'] == 'reveal'
    draw = state[:private_draws][proof['draw_id']]
    return false unless draw && draw[:player].casecmp?(actor.to_s) && draw[:pool] == proof['pool_id']
    values = proof['values']
    pool_cards = state[:private_pools].fetch(draw[:pool])[:cards]
    return false unless GameRoomPrivateCards.valid_reveal_values?(values) && (values & draw[:used]).empty? &&
      values.all? { |value| value <= pool_cards.size } && values.map { |value| pool_cards[value - 1] }.sort == cards.sort
    if positions
      return false unless positions.size == cards.size && positions.uniq.size == positions.size &&
        positions.each_with_index.all? do |position, index|
          position.is_a?(Integer) && position.between?(0, hand.size - 1) &&
            (hand[position] == cards[index] || hand[position].to_s.start_with?("hidden:#{proof['draw_id']}:"))
        end
    end
    hidden = hand.each_index.select { |index| hand[index].to_s.start_with?("hidden:#{proof['draw_id']}:") }
    missing = cards.reject { |card| hand.include?(card) }
    return false if hidden.size < missing.size
    previous = hand.dup
    if positions
      positions.each_with_index { |position, index| hand[position] = cards[index] }
    else
      missing.each_with_index { |card, index| hand[hidden[index]] = card }
    end
    accepted = false
    accepted = yield
    if accepted
      state[:private_draws].fetch(proof['draw_id'])[:used].concat(values)
      state[:private_public] |= cards
    end
    accepted
  ensure
    hand.replace(previous) if previous && !accepted
  end

  def expose_transfer(state, card)
    state[:private_public] |= [card]
  end
end
