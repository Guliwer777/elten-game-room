require_relative '../lib/private_card_effects'

GameRoomPrivateCards.register('uno', host:%w[private_deal private_recycle],
  claim:%w[private_ready private_fact draw pass uno catch challenge turn_timeout buzz choose_colour],
  take:%w[initial_hand private_draw], reveal:%w[play], random:%w[deal])

module GameRoomGames
  module UnoPrivate
    include GameRoomPrivateCardEffects

    def automatic_actor(replay, viewer, table_owner:)
      return viewer if replay.state[:private_cards] && replay.state[:phase] == :playing
      super
    end

    def automatic_action(replay, actor, context: nil)
      state = replay.state
      if state[:private_cards] && state[:phase] == :playing
        return nil unless same_user?(actor, state[:private_viewer]) && same_user?(actor, state[:current_player])
        return {'kind'=>'command', 'action'=>'turn_timeout'} if !state[:buzzer_active] && turn_deadline_reached?(state, context&.now)
        return nil
      end
      super
    end

    def event_sound_cues(event:, before_replay:, after_replay:, history:, **args)
      return super unless after_replay.state[:private_cards]
      return nil if private_waiting?(after_replay.state)
      origin = before_replay.state.dig(:private_effect, :event) || event
      origin = origin.merge('action'=>'deal') if history.any? { |entry| entry.kind == :deal }
      super(event:origin, before_replay:before_replay, after_replay:after_replay, history:history, **args)
    end

    private

    def uno_timeout_actor(state); state[:private_cards] ? state[:current_player] : super; end

    def private_deal_spec(state)
      deck = private_uno_deck(state)
      state[:discard], state[:colour] = [], nil
      state[:draw_pile] = Array.new(deck.size - state[:hands].values.sum(&:size), :private_card)
      state[:private_opened], state[:private_reserved] = false, {}
      {hands:state[:hands], deck:deck}
    end

    def record_uno_deal(state, event, actor, repository, history)
      if state[:private_cards] && event['action'] == 'deal'
        state[:private_opening_event] = event
        return
      end
      super
    end

    def private_dealing_applied(state, event, session, repository, history)
      super
      if !private_waiting?(state) && !state[:private_opened]
        private_apply_effect(state, event.merge('action'=>'private_open'), session, repository, history)
      end
    end

    def private_reduce_effect(state, event, session, repository, history)
      return private_open_uno(state, event, session, repository, history) if event['action'] == 'private_open'
      reduce_event(state, event, session, repository, history)
    end

    # The first non-wild card is chosen AFTER dealing, as in the normal rules.
    # Skipped wilds remain at the front. The dealer owns those temporary
    # receipts and reveals them only when another account actually draws one.
    def private_open_uno(state, event, session, repository, history)
      dealer = state[:players][state[:dealer_index]]
      prefix = []
      loop do
        card = private_effect_input(state, :take, dealer, 1).first
        state[:draw_pile].shift
        if private_hand_decision(state, dealer, "opening-wild:#{prefix.size}") { wild?(card) }
          key = "reserved:#{prefix.size}"
          state[:private_reserved][key] = {actor:dealer, card:card}
          prefix << key
        else
          top = private_disclose_packet(state, dealer, [card], 'opening-card').first
          state[:discard], state[:colour] = [top], card_color(top)
          break
        end
      end
      state[:draw_pile].unshift(*prefix)
      state[:private_opened] = true
      opening = state.delete(:private_opening_event)
      record_uno_deal(state, opening.merge('action'=>'private_open'), repository.actor_of(opening, session), repository, history)
      true
    end

    def private_normalize_plan(plan, state)
      return plan unless plan.events.one? && plan.events.first.action == 'play'
      event = plan.events.first
      card = event.value.split('|').first
      return plan unless card_type(card) == 'A'
      deck = private_uno_deck(state)
      hand = state[:hands].fetch(state[:private_viewer])
      mask = hand.select { |candidate| candidate != card && card_color(candidate) == card_color(card) }.
        reduce(0) { |bits, candidate| bits | (1 << deck.index(candidate)) }
      event_plan('play', "#{event.value.split('|',4).first(3).join('|')}|#{mask.to_s(16)}")
    end

    def private_colour_cards(state, event)
      mask = event['value'].to_s.split('|',4)[3]
      return [] unless mask
      deck = private_uno_deck(state)
      return nil unless /\A[0-9a-f]+\z/.match?(mask) && mask.size <= (deck.size + 3) / 4
      bits = mask.to_i(16)
      return nil if bits.bit_length > deck.size
      deck.each_with_index.filter_map { |card,i| card if bits[i] == 1 }
    end

    def private_event_cards(event, state)
      return [] unless event['action'] == 'play'
      card = event['value'].to_s.split('|').first
      extra = private_colour_cards(state, event)
      return [] unless extra
      [card] + extra
    end

    def private_uno_deck(state)
      cards = uno_deck(state[:options])
      state[:side] == :dark ? cards.map { |card| flip_counterparts.fetch(card,card) } : cards
    end

    def private_selection_preflight?(state, event, actor)
      state[:phase] == :playing && event['action'] == 'play' && active_players(state).any? { |p| same_user?(p,actor) }
    end

    def apply_play(state, event, actor, repository, history)
      return super unless state[:private_cards]
      play = validated_play(state, event, actor)
      return false unless play
      return super if play.late
      packet = private_colour_cards(state, event)
      return false unless packet && packet.all? { |c| c != play.card && card_color(c) == card_color(play.card) }
      return false unless card_type(play.card) == 'A' || packet.empty?
      if card_type(play.card) == 'A' && same_user?(state[:private_viewer], actor) &&
          state[:hands][play.player].none? { |c| GameRoomPrivateCardLedger.hidden?(c) }
        expected = state[:hands][play.player].select { |c| c != play.card && card_color(c) == card_color(play.card) }
        return false unless packet.sort == expected.sort
      end
      state[:private_colour_packet] = packet
      if state[:options]['zero_seven'] && [0,7].include?(card_number(play.card))
        players = card_number(play.card) == 0 ? active_players(state) : [play.player, play.selected_seven_target]
        private_disclose_hands(state, players, 'hand-transfer')
      end
      super
    ensure
      state.delete(:private_colour_packet)
    end

    def discard_colour_cards(state, player, colour)
      state[:private_cards] ? state.fetch(:private_colour_packet) : super
    end

    def challenge_legality(state, player, colour)
      return super unless state[:private_cards]
      state[:private_challenge_answer] = super if same_user?(state[:private_viewer], player)
      :private
    end

    def apply_challenge(state, event, actor, repository, history)
      if state[:private_cards] && state[:challenge_player] && same_user?(state[:challenge_player], actor)
        state[:challenge_legal] = private_hand_decision(state, state[:challenge_source], 'challenge') { state[:private_challenge_answer] }
      end
      super
    end

    def has_playable_card?(state, player)
      private_hand_decision(state, player, 'playable') { super }
    end

    def draw_until(state, player: nil, &condition)
      return super unless state[:private_cards]
      cards = []
      loop do
        card = draw_cards(state, 1, player:player).first
        break unless card
        cards << card
        break if private_hand_decision(state, player, "draw-until:#{cards.size}") { condition.call(card) }
      end
      cards
    end

    def draw_cards(state, count, player: nil)
      return super unless state[:private_cards]
      cards = []
      while cards.size < count.to_i
        if (reserved = state[:private_reserved][state[:draw_pile].first])
          cards.concat(private_disclose_packet(state, reserved[:actor], [reserved[:card]], 'reserved-card'))
          state[:private_reserved].delete(state[:draw_pile].shift)
        else
          boundary = state[:draw_pile].index { |key| state[:private_reserved].key?(key) } || count.to_i
          drawn = private_draw_from_stock(state, player, [count.to_i-cards.size, boundary].min)
          break if drawn.empty?
          cards.concat(drawn)
        end
      end
      cards
    end

    def private_recyclable_cards(state); state[:discard][0...-1] + state[:mercy_cards]; end

    def private_reset_stock(state, count)
      state[:discard] = state[:discard].last(1)
      state[:mercy_cards] = []
      state[:draw_pile] = Array.new(count, :private_card)
      state[:recycle] += 1
    end

    def flip_all_cards(state)
      super
      return unless state[:private_cards]
      counterpart = flip_counterparts
      state[:private_pools].each_value { |pool| pool[:cards].map! { |c| counterpart.fetch(c,c) } }
      state[:private_deck].map! { |c| counterpart.fetch(c,c) }
      state[:private_public].map! { |c| counterpart.fetch(c,c) }
      state[:private_reserved].each_value { |r| r[:card] = counterpart.fetch(r[:card],r[:card]) }
    end

    def finish_round(state, winner, event_id, history)
      private_disclose_hands(state, active_players(state), 'score') if state[:private_cards]
      super
    end

    def apply_no_mercy(state, player, event_id, history, deadline:0)
      if state[:private_cards] && state[:options]['deck'] == 'no_mercy' &&
          state[:options]['no_mercy_limit'].to_i.positive? && state[:hands][player].size >= state[:options]['no_mercy_limit'].to_i
        private_disclose_hands(state, [player], 'elimination')
      end
      super
    end
  end
end
