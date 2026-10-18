require_relative '../lib/private_card_effects'

%w[domino mexican_train].each do |game|
  GameRoomPrivateCards.register(game, host:%w[private_deal private_recycle],
    claim:%w[private_ready private_fact], take:%w[initial_hand private_draw],
    reveal:[game], random:[game])
end

module GameRoomGames
  # Both tile games keep their existing applicator, surfaces and turn rules.
  # Only the shared boundaries for account-owned hands are asynchronous.
  module TileGamePrivate
    include GameRoomPrivateCardEffects

    def automatic_actor(replay, viewer, table_owner:)
      return viewer if replay.state[:private_cards] && replay.state[:phase] == :playing
      super
    end

    def automatic_action(replay, actor, context: nil)
      state = replay.state
      if state[:private_cards] && state[:phase] == :playing
        return nil unless same_user?(actor, state[:private_viewer]) && same_user?(actor, state[:current_player])
        return command('timeout') if deadline_reached?(state, context&.now)
        return command('pass') unless has_placement?(state, actor) || can_draw?(state)
        return nil
      end
      super
    end

    protected

    def automatic_move_actor(state); state[:private_cards] ? state[:current_player] : super; end

    def apply_replay_event(state, event, session, repository, history)
      if state[:private_cards] && event['action'] == id && decode(event['value'].to_s)&.[]('action') == 'deal'
        event = event.merge('action'=>'deal')
      end
      super
    end

    def private_event_cards(event, _state)
      data = event['action'] == id && decode(event['value'].to_s)
      data && data['action'] == 'play' ? [data['tile']] : []
    end

    def private_deal_spec(state)
      deck = (state[:hands].values.flatten + state[:stock]).sort
      state[:stock] = Array.new(state[:stock].size, :private_card)
      {hands:state[:hands], deck:deck}
    end

    def complete_deal(state, data, event_id, history)
      if state[:private_cards] && !state[:private_effect_cursor]
        state[:private_tile_deal] = data
        return
      end
      super
    end

    def private_dealing_applied(state, event, session, repository, history)
      super
      if !private_waiting?(state) && state[:private_tile_deal]
        private_apply_effect(state, event, session, repository, history)
      end
    end

    def private_reduce_effect(state, event, session, repository, history)
      if state[:private_tile_deal]
        complete_deal(state, state.delete(:private_tile_deal), repository.event_id(event), history)
        return true
      end
      data = decode(event['value'].to_s)
      data && apply(state, data, repository.actor_of(event, session), repository.event_id(event), history) == :ok
    end

    def opening_tile_rank(state, player)
      private_hand_number(state, player, 'opening_tile', range:0..118) { super }
    end

    def has_placement?(state, player)
      private_hand_decision(state, player, 'placement') { super }
    end

    def drawn_tile_playable?(state, player, tile)
      private_hand_decision(state, player, 'drawn_tile') { super }
    end

    def draw_one(state, player)
      return super unless state[:private_cards] && state.key?(:private_effect_cursor)
      tile = private_draw_from_stock(state, player, 1, stock: :stock).first
      state[:hands][player] << tile if tile
      state[:voids].delete(player) if tile
      tile
    end

    def private_recyclable_cards(_state); []; end

    def finish_round(state, winner, event_id, history)
      if state[:private_cards]
        return unless state.key?(:private_effect_cursor)
        private_disclose_hands(state, active_players(state), 'score')
      end
      super
    end
  end
end
