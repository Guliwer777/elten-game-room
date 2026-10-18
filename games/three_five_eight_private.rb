require_relative '../lib/private_card_game'
require_relative '../lib/private_card_round_audit'

GameRoomPrivateCards.register('three_five_eight', host: %w[private_deal],
  claim: %w[private_ready choose_contract stop_exchange], take: %w[initial_hand private_draw],
  reveal: %w[exchange return discard play], random: %w[deal])

module GameRoomGames
  module ThreeFiveEightPrivate
    include GameRoomPrivateCardGame

    def automatic_action(replay, actor, context: nil)
      state = replay.state
      if state[:private_cards] && state[:phase] == :exchange_return &&
          same_user?(actor, state[:current_player]) && same_user?(actor, state[:private_viewer]) &&
          card_suit(state[:pending_exchange][:card]) != state[:contract]
        return {'kind'=>'card', 'action'=>'return', 'card'=>exchange_return_cards(state, actor).first}
      end
      super
    end

    def automatic_actor(replay, viewer, table_owner:)
      return viewer if replay.state[:private_cards] && replay.state[:phase] == :exchange_return
      super
    end

    private

    def private_event_card(event, _state)
      event['value'].to_s.split('|').last if %w[exchange return discard play].include?(event['action'])
    end

    def private_deal_spec(state)
      deck = state[:complete_hands].values.flatten + state[:kitty]
      state[:complete_hands], state[:kitty] = {}, []
      GameRoomPrivateCardRoundAudit.begin_round(state)
      {hands: state[:hands], deck: deck}
    end

    def apply_choose_contract(state, event, actor, repository, history)
      state[:complete_hands] = state[:hands].transform_values(&:dup) if state[:private_cards]
      super
    end

    def begin_kitty(state, event_id, history)
      return super unless state[:private_cards] && state[:kitty].empty?
      private_request_draw(state, actor: state[:chooser], count: 4, purpose: 'kitty')
    end

    def private_received_cards(state, _purpose, cards, event, repository, history)
      state[:kitty] = cards
      begin_kitty(state, repository.event_id(event), history)
    end

    def exchange_return_cards(state, actor)
      pending = state[:pending_exchange]
      if state[:private_cards] && pending && card_suit(pending[:card]) != state[:contract]
        return [highest_card_of_suit(hand_for(state, actor), card_suit(pending[:card]))].compact
      end
      super
    end

    def private_after_event(state, event, session, repository, history)
      if event['action'] == 'choose_contract'
        GameRoomPrivateCardDealing.append(state, state[:players].to_h { |player| [player, 10] })
      end
      card = private_event_card(event, state)
      GameRoomPrivateCardLedger.expose_transfer(state, card) if %w[exchange return].include?(event['action'])
      state[:private_round_actions] << event unless event['action'] == 'private_draw'
      return unless [:round_complete, :finished].include?(state[:phase])
      audit = GameRoomPrivateCardRoundAudit.initial_state(state)
      if audit
        audit[:complete_hands] = audit[:hands].transform_values(&:dup)
        audit[:hands] = state[:players].to_h { |player| [player, []] }
        state[:private_draws].each_value do |draw|
          next unless draw[:initial] && draw[:group] == 0
          cards = state[:private_pools].fetch(draw[:pool])[:cards]
          audit[:hands][draw[:player]].concat(draw[:used].map { |index| cards[index - 1] })
        end
        audit[:kitty] = state[:kitty].dup
      end
      expected_return = nil
      valid = audit && state[:private_round_actions].all? do |item|
        actor = repository.actor_of(item, session)
        if expected_return
          target, expected = expected_return
          expected_return = nil
          item['action'] == 'return' && same_user?(actor, target) && item['value'] == expected
        else
          if item['action'] == 'exchange'
            target, offered = item['value'].split('|')
            if card_suit(offered) != audit[:contract]
              expected_return = [target, highest_card_of_suit(audit[:hands][target] + [offered], card_suit(offered))]
            end
          end
          apply_replay_event(audit, item, session, repository, [])
        end
      end
      GameRoomPrivateCardRoundAudit.reject_round(state, event, repository, history) unless valid
    end
  end
end
