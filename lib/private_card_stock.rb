require_relative 'private_card_effects'

# A stock may contain cards from several native pools after a return/exchange.
# Shuffle only pool tickets with the authenticated move seed; the native pool
# supplies each ticket's secret value. This preserves returning before drawing,
# including the chance of drawing back the very same card, without exposing
# other hands or rebuilding the entire stock from their secrets.
module GameRoomPrivateCardStock
  include GameRoomPrivateCardEffects

  private

  def private_stock_ticket(pool)
    "pool:#{pool}"
  end

  def private_stock_fill(state, stock:)
    state[stock] = Array.new(state[stock].size, private_stock_ticket(state[:private_pool]))
  end

  def private_stock_return(state, cards, seed:, stock:)
    return if cards.empty?
    pool = private_effect_input(state, :recycle, nil, cards)
    tickets = state[stock] + Array.new(cards.size, private_stock_ticket(pool))
    state[stock] = GameRoomRandom.shuffle(tickets, random:Random.new(seed.to_i(16)))
  end

  def private_stock_take(state, actor, count, stock:)
    cards = []
    while cards.size < count && !state[stock].empty?
      ticket = state[stock].first
      raise 'Invalid private stock ticket' unless ticket.is_a?(String) && ticket.start_with?('pool:')
      pool = ticket.delete_prefix('pool:')
      amount = [count - cards.size, state[stock].take_while { |entry| entry == ticket }.size, 100].min
      cards.concat(private_effect_input(state, :take, actor, {count:amount, pool:pool}))
      state[stock].shift(amount)
    end
    cards
  end
end
