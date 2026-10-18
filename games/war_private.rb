require_relative '../lib/private_card_game'

GameRoomPrivateCards.register('war', host: %w[private_deal], claim: %w[private_ready],
  take: %w[initial_hand], reveal: %w[play], random: %w[deal], ordered: true)

module GameRoomGames
  module WarPrivate
    include GameRoomPrivateCardGame

    private

    def private_deal_spec(state)
      hands = state[:piles]
      state[:piles] = state[:players].to_h { |player| [player, []] }
      {hands: hands, deck: war_deck(state[:options])}
    end

    def private_dealing_applied(state, _event, _session, _repository, _history)
      state[:piles] = state[:hands]
    end

    def private_normalize_plan(plan, state)
      event = plan.events.first
      return plan unless event.action == 'play'
      cards = pile(state, current_actor(state))
      count = state[:depth] > 0 && cards.size >= 2 ? 2 : 1
      ActionPlan.new(events: [EventCommand.new(action: 'play', value: event.value + '|' + cards.first(count).join(','))])
    end

    def private_event_cards(event, _state)
      event['action'] == 'play' ? event['value'].to_s.split('|', 2).last.to_s.split(',') : []
    end

    def private_reveal_positions(state, _event, actor)
      count = state[:depth] > 0 && pile(state, actor).size >= 2 ? 2 : 1
      (0...count).to_a
    end

    def apply_play(state, event, actor, repository, history)
      return super unless state[:private_cards]
      key, values = event['value'].to_s.split('|', 2)
      cards = values.to_s.split(',')
      return false unless cards == pile(state, actor).first(private_reveal_positions(state, event, actor).size)
      super(state, event.merge('value'=>key), actor, repository, history)
    end

    def private_after_event(state, event, _session, _repository, _history)
      # Cards placed on the table can subsequently pass to another account.
      # Their face-down presentation stays unchanged; unplayed piles remain private.
      state[:private_public] |= private_event_cards(event, state) if event['action'] == 'play'
    end
  end
end
