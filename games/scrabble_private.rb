require_relative '../lib/private_card_payload'
require_relative '../lib/private_card_stock'

GameRoomPrivateCards.register('scrabble', host:%w[private_deal private_recycle],
  claim:%w[private_ready scrabble], take:%w[initial_hand private_draw], random:%w[scrabble],
  player_random:%w[exchange], payload:true)

module GameRoomGames
  module ScrabblePrivate
    include GameRoomPrivateCardPayload
    include GameRoomPrivateCardStock

    def automatic_actor(replay, viewer, table_owner:)
      return viewer if replay.state[:private_cards] && replay.state[:phase] == :playing
      super
    end

    def automatic_action(replay, actor, context: nil)
      state = replay.state
      if state[:private_cards] && state[:phase] == :playing
        return {'action'=>'timeout'} if same_user?(actor, state[:private_viewer]) &&
          same_user?(actor, state[:current_player]) && expired?(state, context&.now)
        return nil
      end
      super
    end

    private

    def copy_state(state)
      state.is_a?(Hash) && state[:private_cards] ? GameRoomSnapshot.copy(state) : super
    end
    def timeout_actor(state); state[:private_cards] ? state[:current_player] : super; end

    def private_payload_cards(data, _state)
      case data['action']
      when 'place'
        placements = data['placements']
        placements.is_a?(Array) && placements.all? { |item| item.is_a?(Array) } ? placements.map(&:first) : nil
      when 'exchange' then data['tiles']
      else []
      end
    end

    def private_selection_preflight?(state, event, actor)
      data = event['__payload']
      data && state[:phase] == :playing && same_user?(state[:current_player], actor) &&
        data['revision'] == state[:revision] && data['time'].is_a?(Integer) && data['time'] >= state[:turn_started]
    end

    def private_deal_spec(state)
      state[:bag] = Array.new(state[:bag].size, :private_card)
      {hands:state[:racks], deck:(0...tiles(state).size).to_a}
    end

    def private_dealing_applied(state, event, session, repository, history)
      state[:racks] = state[:hands]
      private_stock_fill(state, stock: :bag) if !private_waiting?(state) && event['action'] == 'initial_hand'
      super
    end

    def private_reduce_effect(state, event, session, repository, history)
      state[:racks] = state[:hands]
      data = event['__payload']
      data && apply(state, data, repository.actor_of(event, session), repository.event_id(event), history) == :ok
    end

    def draw_tiles(state, player, count)
      return super unless state[:private_cards] && state.key?(:private_effect_cursor)
      private_stock_take(state, player, count, stock: :bag)
    end

    def return_tiles(state, ids, seed)
      return super unless state[:private_cards] && state.key?(:private_effect_cursor)
      private_stock_return(state, ids, seed:seed, stock: :bag)
    end

    def finish(state, finisher, event_id, history)
      if state[:private_cards]
        return unless state.key?(:private_effect_cursor)
        private_disclose_hands(state, state[:players], 'score')
      end
      super
    end
  end
end
