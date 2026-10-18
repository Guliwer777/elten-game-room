require_relative '../lib/private_card_game'

GameRoomPrivateCards.register('ninety_nine', host: %w[private_deal private_recycle turn_timeout],
  claim: %w[private_ready no_cards], take: %w[initial_hand private_draw],
  reveal: %w[play], random: %w[deal])

module GameRoomGames
  module NinetyNinePrivate
    include GameRoomPrivateCardGame

    private

    def private_event_card(event, _state)
      event['value'].to_s.split('|').first if event['action'] == 'play'
    end

    def private_normalize_plan(plan, _state)
      # The standard two-part rule is retained; only its private replacement
      # draw needs a separate account-owned server receipt.
      event = plan.events.first
      return plan unless event.action == 'play_draw'
      ActionPlan.new(events: [EventCommand.new(action: 'play', value: event.value)])
    end

    def private_deal_spec(state)
      deck = deck_for(state[:players].size)
      state[:draw_pile] = Array.new(deck.size - state[:hands].values.sum(&:size), :private_card)
      {hands: state[:hands], deck: deck}
    end

    def private_after_event(state, event, _session, _repository, _history, *_args)
      return unless event['action'] == 'play' && state[:phase] == :awaiting_draw
      private_request_draw(state, actor: state[:current_player], count: 1, purpose: 'replacement', public: false)
      return unless state[:draw_pile].empty?
      cards = state[:discard][0...-1]
      return if cards.empty?
      state[:discard] = state[:discard].last(1)
      state[:draw_pile] = Array.new(cards.size, :private_card)
      state[:recycle_count] += 1
      GameRoomPrivateCardDealing.recycle(state, cards, players: active_players(state))
    end

    def private_received_cards(state, _purpose, cards, event, repository, history)
      # Feed just this receipt to the unchanged draw/turn rule. The rest of
      # the pile remains opaque, including after a host transfer.
      state[:draw_pile][0, cards.size] = cards
      apply_draw(state, event, state[:current_player], repository, history)
    end
  end
end
