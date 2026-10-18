require_relative '../lib/private_card_payload'

GameRoomPrivateCards.register('rummy', host: %w[private_deal private_recycle],
  claim: %w[private_ready rummy], take: %w[initial_hand private_draw], random: %w[rummy], payload: true)

module GameRoomGames
  module RummyPrivate
    include GameRoomPrivateCardPayload

    def automatic_actor(replay, viewer, table_owner:)
      return viewer if replay.state[:private_cards] && replay.state[:phase] == :playing
      super
    end

    def automatic_action(replay, actor, context: nil)
      state = replay.state
      if state[:private_cards] && state[:phase] == :playing
        return command('timeout') if same_user?(actor, state[:private_viewer]) &&
          same_user?(actor, state[:current_player]) && deadline_reached?(state, context&.now)
        return nil
      end
      super
    end

    def automatic_action_due?(replay, actor, context: nil)
      return super unless replay.state[:private_cards]
      same_user?(actor, replay.state[:current_player]) && deadline_reached?(replay.state, context&.now)
    end

    private

    def timeout_actor(state); state[:private_cards] ? state[:current_player] : super; end

    def private_payload_cards(data, _state)
      case data['action']
      when 'meld' then data['groups'].is_a?(Array) ? data['groups'].flatten : nil
      when 'add', 'discard' then [data['card']]
      else []
      end
    end

    def private_deal_spec(state)
      copies = state[:options]['identities'] ? 4 : active_players(state).size <= 4 ? 2 : active_players(state).size <= 6 ? 3 : 4
      deck = Rummy::Rules.deck(copies)
      state[:stock] = Array.new(deck.size - state[:hands].values.sum(&:size), :private_card)
      state[:private_turn_initial_hand] = []
      {hands: state[:hands], deck: deck}
    end

    def private_dealing_applied(state, event, _session, _repository, _history)
      return if private_waiting?(state)
      if event['action'] == 'initial_hand'
        state[:private_turn_initial_hand] = state[:hands].fetch(state[:current_player]).dup
      end
    end

    def private_after_event(state, _event, _session, _repository, _history)
      state[:private_public] |= state[:discard] + state[:melds].flat_map { |meld| meld[:cards] }
    end

    def private_disclosure_applied(state, event, actor)
      return unless same_user?(actor, state[:current_player] || state.dig(:private_disclosure, :resume, 1))
      proof = event['__server_pool']
      cards = proof['values'].map { |value| state[:private_pools].fetch(proof['pool_id'])[:cards][value - 1] }
      initial = state[:private_turn_initial_hand]
      cards.each do |card|
        next if initial.include?(card)
        slot = initial.index { |item| item.to_s.start_with?("hidden:#{proof['draw_id']}:") }
        initial[slot] = card if slot
      end
    end

    def apply(state, data, actor, event_id, history)
      if state[:private_cards] && !state[:private_applying_draw] && state[:phase] == :playing &&
          ((data['action'] == 'draw' && data.fetch('depth', 0) == 0) ||
           (data['action'] == 'timeout' && !state[:drawn] && (!state[:stock].empty? || state[:discard].size > 1)))
        # Validate the ordinary move before scheduling its account-owned draw.
        candidate = copy_state(state)
        status = super(candidate, data, actor, event_id, [])
        return status unless status == :ok
        state[:private_rummy_draw] = {data: data, actor: actor, event_id: event_id}
        private_request_draw(state, actor: state[:current_player], count: 1, purpose: 'stock', public: false)
        if state[:stock].empty?
          cards = state[:discard][0...-1]
          state[:discard] = state[:discard].last(1)
          state[:stock] = Array.new(cards.size, :private_card)
          state[:recycle] += 1
          GameRoomPrivateCardDealing.recycle(state, cards, players: active_players(state))
        end
        return :ok
      end
      super
    end

    def begin_turn(state, time)
      super
      state[:private_turn_initial_hand] = state.delete(:turn_initial_hand) if state[:private_cards]
    end

    def turn_progress?(state)
      return super unless state[:private_cards]
      state[:drawn] || !(state[:private_turn_initial_hand] & state[:melds].flat_map { |meld| meld[:cards] }).empty?
    end

    def private_received_cards(state, _purpose, cards, _event, _repository, history)
      pending = state.delete(:private_rummy_draw)
      state[:stock][0, cards.size] = cards
      state[:private_applying_draw] = true
      result = apply(state, pending[:data], pending[:actor], pending[:event_id], history)
      state[:private_error] = :invalid_draw_continuation unless result == :ok
    ensure
      state.delete(:private_applying_draw)
    end

    def finish_round(state, winner, event_id, history)
      if state[:private_cards] && GameRoomPrivateCardDisclosure.prepare(state, active_players(state), purpose: 'score')
        state[:private_rummy_winner] = winner
        return
      end
      super
    end

    def private_disclosure_completed(state, purpose, event, session, repository, history)
      return super unless purpose == 'score'
      finish_round(state, state.delete(:private_rummy_winner), repository.event_id(event), history)
    end
  end
end
