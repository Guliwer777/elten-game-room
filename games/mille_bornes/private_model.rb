module GameRoomGames
  using GameRoomLocalization::Translations

  class MilleBornes
    private

    def apply_private_event(state, event, actor, event_id, history)
      GameRoomPrivateCardLedger.observe_reveal(state, event, actor)
      return false if state[:private_error]
      case event['action']
      when 'private_deal', 'private_recycle'
        apply_private_pool(state, event, actor, event_id, history)
      when 'private_ready'
        apply_private_ready(state, event, actor)
      when 'draw_intent'
        return false unless state[:phase] == :awaiting_draw && same_user?(state[:current_player], actor)
        state[:phase] = :awaiting_confirmed_draw
        state[:reaction] = nil
        true
      when 'initial_hand', 'draw', 'bonus_draw'
        apply_private_take(state, event, actor, event_id, history)
      when 'play', 'discard', 'dirty_trick'
        apply_private_reveal(state, event, actor, event_id, history)
      else
        false
      end
    end

    def apply_private_pool(state, event, actor, event_id, history)
      fresh = event['action'] == 'private_deal'
      return false unless private_pool_needed?(state) &&
        fresh == [:awaiting_deal, :round_complete].include?(state[:phase])
      return false if options_error(state[:options], player_count: state[:players].length)
      fields = event['value'].to_s.split('|', -1)
      round = fresh ? state[:round] + 1 : state[:round]
      return false unless fields.length == 2 && fields[0] == round.to_s && fields[1].match?(/\A[A-Za-z0-9_-]{16,64}\z/)
      return false if state[:private_pools].key?(fields[1])
      cards = fresh ? deck_for(state[:options]) : state[:discard].dup
      state[:private_retired] |= private_retirable_pools(state, fresh: fresh)
      if fresh
        reset_private_round(state, round, fields[1])
        add_history(history, event_id, actor, :deal, _("Round %{round}. Six cards dealt to each player.") % {round: round})
      else
        state[:private_after_ready] = state[:phase]
        state[:private_public] -= cards
        state[:discard] = []
        state[:recycle_count] += 1
      end
      state[:private_pool] = fields[1]
      state[:private_pools][fields[1]] = {cards: cards, remaining: cards.length}
      state[:private_ready] = []
      state[:draw_pile] = Array.new(cards.length, :private_card)
      state[:phase] = :private_wait
      true
    end

    def reset_private_round(state, round, identity)
      state.merge!(round: round, seed: identity, hands: state[:players].to_h { |player| [player, []] },
        tracks: Array.new(state[:scores].length) { fresh_track }, discard: [], spent: [], recycle_count: 0,
        action_number: 0, reaction: nil, round_winner: nil, round_scores: [], private_initial: [],
        private_draws: {}, private_pools: {}, private_known: {}, private_public: [], private_retired: [], private_bonus: nil, private_after_ready: :private_dealing, current_player: nil)
    end

    def apply_private_ready(state, event, actor)
      player = player_key(state, actor)
      return false unless player && state[:phase] == :private_wait && event['value'] == state[:private_pool]
      return false if state[:private_ready].include?(player)
      state[:private_ready] << player
      state[:phase] = state[:private_after_ready] if state[:private_ready].length == state[:players].length
      true
    end

    def valid_private_take?(state, event, player)
      proof = event['__server_pool']
      return false unless proof && proof['operation'] == 'take' && proof['pool_id'] == state[:private_pool]
      return false if state[:private_draws].key?(proof['draw_id'])
      initial = event['action'] == 'initial_hand'
      if initial
        return false unless state[:phase] == :private_dealing && !state[:private_initial].include?(player)
      else
        phase = event['action'] == 'bonus_draw' ? :awaiting_bonus_draw : :awaiting_draw
        allowed = state[:phase] == phase || (phase == :awaiting_draw && state[:phase] == :awaiting_confirmed_draw)
        return false unless allowed && same_user?(state[:current_player], player)
        return false if phase == :awaiting_draw && state[:reaction]
      end
      return false unless proof['count'] == (initial ? 6 : 1)
      pool = state[:private_pools].fetch(state[:private_pool])
      unless proof['remaining'] == pool[:remaining] - proof['count'] && proof['remaining'] >= 0
        state[:private_error] = :unexpected_draw
        state[:phase] = :private_error
        return false
      end
      true
    end

    def apply_private_take(state, event, actor, event_id, history)
      player = player_key(state, actor)
      return false unless player && valid_private_take?(state, event, player)
      proof = event.fetch('__server_pool')
      pool = state[:private_pools].fetch(state[:private_pool])
      pool[:remaining] = proof['remaining']
      state[:private_draws][proof['draw_id']] = {pool: proof['pool_id'], player: player, count: proof['count'], used: []}
      state[:private_receipt] = proof
      if event['action'] == 'initial_hand'
        draw_private_card(state, player)
        state[:private_initial] << player
        if state[:private_initial].length == state[:players].length
          begin_turn(state, state[:players][(state[:round] - 1) % state[:players].length])
        end
        true
      elsif event['action'] == 'bonus_draw'
        draw_private_card(state, player)
        state[:private_bonus] = nil
        begin_turn(state, player)
        true
      else
        state[:phase] = :awaiting_draw if state[:phase] == :awaiting_confirmed_draw
        apply_standard_event(state, event, actor, event_id, history)
      end
    ensure
      state.delete(:private_receipt)
    end

    def draw_private_card(state, player)
      proof = state.delete(:private_receipt)
      unless proof
        state[:private_bonus] = player
        return
      end
      cards = state[:private_pools].fetch(proof['pool_id'])[:cards]
      values = state[:private_values][proof['draw_id']]
      proof['count'].times do |index|
        value = values && values[index]
        card = value.is_a?(Integer) && value.between?(1, cards.length) ? cards[value - 1] : nil
        state[:hands][player] << (card || "hidden:#{proof['draw_id']}:#{index}")
        state[:draw_pile].shift
      end
    end

    def apply_private_reveal(state, event, actor, event_id, history)
      selection = selection_from_event(event)
      player = player_key(state, actor)
      return false unless selection && player
      GameRoomPrivateCardLedger.with_cards(state, event, actor,
          hand:state[:hands].fetch(player), cards:[selection['card']]) do
        apply_standard_event(state, event, actor, event_id, history)
      end
    end
  end
end
