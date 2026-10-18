require_relative 'private_card_ledger'

# Initial hand delivery shared by fixed-deal card games. Models retain their
# existing deal/turn rules; the session runner executes these ordinary plans.
module GameRoomPrivateCardDealing
  module_function

  def prepare(state, hands, deck: hands.values.flatten)
    state[:private_deck] = deck
    state[:private_counts] = hands.transform_values(&:size)
    state[:private_append] = false
    state[:private_fresh] = true
    state[:private_required] = state[:private_counts].select { |_, count| count.positive? }.keys
    # Games that draw their opening cards one at a time still validate the
    # pool on every participating account before the first private draw.
    state[:private_required] = hands.keys if state[:private_required].empty?
    state[:private_deal_group] = 0
    state[:private_resume] = [state[:phase], state[:current_player]]
    state[:hands] = hands.to_h { |player, _| [player, []] }
    state[:phase] = :private_prepare
    state[:current_player] = nil
  end

  # The same delivery protocol can recycle publicly played cards without
  # retiring pools that still contain unexposed hands.
  def recycle(state, cards, players: state[:players])
    state[:private_deck] = cards.dup
    state[:private_fresh] = false
    state[:private_required] = players.dup
    state[:private_resume] = [state[:phase], state[:current_player]]
    state[:phase], state[:current_player] = :private_prepare, nil
    retained = state[:private_pools].keys - state[:private_retired] - GameRoomPrivateCardLedger.retirable_pools(state)
    state[:private_error] = :pool_limit if retained.size >= GameRoomPrivateCards::MAX_POOLS
  end

  def append(state, counts)
    state[:private_counts] = counts
    state[:private_append] = true
    state[:private_deal_group] += 1
    state[:private_initial] = counts.select { |_, count| count.zero? }.keys
    state[:private_resume] = [state[:phase], state[:current_player]]
    state[:phase], state[:current_player] = :private_dealing, nil
  end

  def automatic(state, actor, owner:)
    return nil if state[:private_error]
    case state[:phase]
    when :private_prepare
      return nil unless state[:private_viewer].to_s.casecmp?(owner.to_s)
      state[:private_fresh] ? 'private_deal' : 'private_recycle'
    when :private_wait, :private_dealing
      player = state[:players].find { |name| name.casecmp?(actor.to_s) }
      return nil unless player && state[:private_viewer].to_s.casecmp?(actor.to_s)
      if state[:phase] == :private_wait
        'private_ready' if state[:private_required].include?(player) && !state[:private_ready].include?(player)
      else
        'initial_hand' if state[:private_counts][player].to_i > 0 && !state[:private_initial].include?(player)
      end
    end
  end

  def command(state, action, actor)
    case action
    when 'private_deal', 'private_recycle'
      GameRoomPrivateCards.command(action, state[:round].to_s, operation: 'create', size: state[:private_deck].size,
        retire: GameRoomPrivateCardLedger.retirable_pools(state, fresh: state[:private_fresh]))
    when 'private_ready'
      GameRoomPrivateCards.command(action, state[:private_pool], operation: 'check', pool_id: state[:private_pool],
        size: state[:private_deck].size)
    when 'initial_hand'
      GameRoomPrivateCards.command(action, '', operation: 'take', pool_id: state[:private_pool],
        count: state[:private_counts].fetch(actor))
    end
  end

  def apply(state, event, actor)
    return false if state[:private_error]
    player = state[:players].find { |name| name.casecmp?(actor.to_s) }
    return false unless player
    case event['action']
    when 'private_deal', 'private_recycle'
      round, pool_id = event['value'].to_s.split('|', -1)
      return false unless state[:phase] == :private_prepare && round == state[:round].to_s &&
        GameRoomPrivateCards.pool_id?(pool_id) && !state[:private_pools].key?(pool_id) &&
        (event['action'] == 'private_deal') == state[:private_fresh]
      state[:private_pool] = pool_id
      if state[:private_fresh]
        state[:private_pools], state[:private_draws] = {}, {}
        state[:private_known] = {}
        state[:private_public], state[:private_retired] = [], []
      else
        state[:private_retired] |= GameRoomPrivateCardLedger.retirable_pools(state)
        # Recycled cards acquire new secret positions in the server pool.
        state[:private_public] -= state[:private_deck]
      end
      state[:private_pools][pool_id] = {cards: state[:private_deck].dup, remaining: state[:private_deck].size}
      state[:private_ready] = []
      state[:private_initial] = state[:private_counts].select { |_, count| count.zero? }.keys
      state[:phase] = :private_wait
    when 'private_ready'
      return false unless state[:phase] == :private_wait && event['value'] == state[:private_pool] &&
        state[:private_required].include?(player) && !state[:private_ready].include?(player)
      state[:private_ready] << player
      if state[:private_ready].size == state[:private_required].size
        if state[:private_fresh] && state[:private_initial].size < state[:players].size
          state[:phase] = :private_dealing
        else
          state[:phase], state[:current_player] = state[:private_resume]
        end
      end
    when 'initial_hand'
      return false unless state[:phase] == :private_dealing && !state[:private_initial].include?(player)
      hand = GameRoomPrivateCardLedger.record_take(state, event, player, count: state[:private_counts].fetch(player))
      return false unless hand
      state[:private_draws].fetch(event['__server_pool']['draw_id'])[:initial] = true
      state[:private_draws].fetch(event['__server_pool']['draw_id'])[:group] = state[:private_deal_group]
      state[:hands][player] = state[:private_append] ? state[:hands][player] + hand : hand
      state[:private_initial] << player
      if state[:private_initial].size == state[:players].size
        state[:phase], state[:current_player] = state[:private_resume]
      end
    else
      return false
    end
    true
  end
end
