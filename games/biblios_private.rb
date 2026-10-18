require_relative '../lib/private_card_effects'

GameRoomPrivateCards.register('biblios', host:%w[private_deal],
  claim:%w[private_ready private_fact allocate take church bid],
  take:%w[private_draw], reveal:%w[pay], random:%w[start], deals:%w[start])

module GameRoomGames
  module BibliosPrivate
    include GameRoomPrivateCardEffects

    private

    def private_deal_spec(state)
      # Leaving the random setup removals undrawn is equivalent to dropping
      # that many shuffled cards, without publishing which cards were removed.
      deck = setup_deck(state[:players])
      state[:deck] = Array.new(state[:deck].size, :private_card)
      state[:private_gift] = {}
      state[:private_auction] = {}
      {hands:state[:hands], deck:deck}
    end

    def private_event_cards(event, _state)
      event['action'] == 'pay' ? (parse_cards(event['value']) || []) : []
    end

    def private_selection_preflight?(state, event, actor)
      state[:phase] == :pay && event['action'] == 'pay' && same_user?(state[:current_player], actor)
    end

    def private_dealing_applied(state, event, session, repository, history)
      super
      unless private_waiting?(state)
        private_apply_effect(state, event.merge('action'=>'private_gift'), session, repository, history)
      end
    end

    def private_reduce_effect(state, event, session, repository, history)
      accepted = event['action'] == 'private_gift' || reduce_event(state, event, session, repository, history)
      if accepted && state[:phase] == :allocate && state[:private_gift][:position] != state[:pointer]
        actor = state[:leader]
        card = private_effect_input(state, :take, actor, 1).first
        state[:private_gift] = {position:state[:pointer], card:card, actor:actor,
          reference:"hidden:#{state[:private_draws].keys.last}:0"}
      end
      accepted
    end

    def gift_card(state)
      state[:private_cards] ? state[:private_gift][:card] : super
    end

    def apply_allocate(state, event, actor, repository, history)
      return super unless state[:private_cards]
      return false unless state[:phase] == :allocate && same_user?(state[:current_player], actor) &&
        allocation_places(state).include?(event['value'])
      card = gift_card(state)
      if event['value'] == 'public'
        state[:private_gift][:card] = private_disclose_packet(state, actor, [card], 'public-gift').first
      elsif event['value'] == 'auction'
        gift = state[:private_gift]
        state[:private_auction][gift[:reference]] = gift.slice(:actor, :card)
        state[:private_gift][:card] = gift[:reference]
      end
      super
    end

    def acquire(state, player, card, resume, event_id, history, revealed: false)
      if state[:private_cards] && !revealed
        # Only a Church card is immediately shown by the ordinary rules.
        if private_hand_decision(state, player, "church:#{event_id}") { church?(card) }
          card = private_disclose_packet(state, player, [card], 'church-gift').first
        end
      end
      super
    end

    def start_auction(state, event_id, history)
      if state[:private_cards] && state[:pointer] < state[:deck].size
        reference = state[:deck][state[:pointer]]
        gift = state[:private_auction].fetch(reference)
        state[:deck][state[:pointer]] = private_disclose_packet(state, gift[:actor], [gift[:card]], 'auction-card').first
      end
      super
    end

    def penalise(state, player, event_id, history)
      if state[:private_cards]
        candidates = state[:hands][player].each_with_index.to_a
        recipients = state[:options]['penalty'] == 'full' ? others_in_order(state[:players], player) : [player]
        selected = recipients.filter_map do |recipient|
          next if candidates.empty?
          candidates.delete_at(random_index(state, event_id, candidates.size, recipient))
        end
        cards = private_disclose_packet(state, player, selected.map(&:first), 'penalty')
        selected.each_with_index { |(_,position), i| state[:hands][player][position] = cards[i] }
      end
      super
    end

    def conclude_game(state, event_id, history)
      private_disclose_hands(state, state[:players], 'score') if state[:private_cards]
      super
    end
  end
end
