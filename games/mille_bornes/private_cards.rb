require_relative '../../lib/private_cards'
require_relative '../../lib/private_card_ledger'

GameRoomPrivateCards.register('mille_bornes', host: %w[private_deal private_recycle],
  claim: %w[private_ready draw_intent], take: %w[initial_hand draw bonus_draw],
  reveal: %w[play discard dirty_trick])

module GameRoomGames
  using GameRoomLocalization::Translations

  class MilleBornes
    def automatic_action_allowed?(replay, actor, table_owner:)
      return super unless replay.state[:private_cards]
      same_user?(actor, table_owner) || replay.players.any? { |player| same_user?(player, actor) }
    end

    def automatic_actor(replay, viewer, table_owner:)
      return super unless replay.state[:private_cards]
      if private_pool_needed?(replay.state) && same_user?(viewer, table_owner)
        replay.players.first
      else
        viewer
      end
    end

    private

    def initialize_private_cards(state, session)
      GameRoomPrivateCardLedger.initialize_state(state, session)
    end

    def private_retirable_pools(state, fresh: false)
      GameRoomPrivateCardLedger.retirable_pools(state, fresh: fresh)
    end

    def finish_private_replay(state, history, event_id)
      if private_pool_needed?(state) && ![:awaiting_deal, :round_complete].include?(state[:phase])
        retained = state[:private_pools].keys - state[:private_retired] - private_retirable_pools(state)
        state[:private_error] = :pool_limit if retained.length >= GameRoomPrivateCards::MAX_POOLS
      end
      return unless state[:private_error]
      state[:phase] = :private_error
      add_history(history, event_id, '', :private_error, private_error_text(state))
    end

    def private_pool_needed?(state)
      return false if state[:private_error]
      [:awaiting_deal, :round_complete].include?(state[:phase]) ||
        ([:awaiting_draw, :awaiting_bonus_draw].include?(state[:phase]) &&
          state[:draw_pile].empty? && state[:options]['recycle_discard'] && !state[:discard].empty?)
    end

    def private_automatic_action(replay, actor, context)
      state = replay.state
      return nil if replay.finished? || state[:private_error]
      return nil if options_error(state[:options], player_count: state[:players].length)
      if private_pool_needed?(state)
        return nil unless same_user?(state[:private_viewer], context&.table_owner)
        action = [:awaiting_deal, :round_complete].include?(state[:phase]) ? 'private_deal' : 'private_recycle'
        return {'kind' => 'command', 'action' => action}
      end
      player = player_key(state, actor)
      return nil unless player && same_user?(actor, state[:private_viewer])
      action = if state[:phase] == :private_wait && !state[:private_ready].include?(player)
        'private_ready'
      elsif state[:phase] == :private_dealing && !state[:private_initial].include?(player)
        'initial_hand'
      elsif state[:phase] == :awaiting_bonus_draw && same_user?(player, state[:current_player])
        'bonus_draw'
      elsif state[:phase] == :awaiting_confirmed_draw && same_user?(player, state[:current_player])
        'draw'
      end
      {'kind' => 'command', 'action' => action} if action
    end

    def private_action_for(selection, replay, actor, context)
      state = replay.state
      return [:finished, nil] if replay.finished?
      return [:invalid, nil] if state[:private_error]
      automatic = private_automatic_action(replay, actor, context)
      if automatic && automatic == selection
        command = private_automatic_command(state, selection['action'])
        return [:ok, ActionPlan.new(events: [command])]
      end
      requested = normalize_selection(selection)
      candidate = legal_actions(replay, actor).find { |action| action == requested }
      return [:invalid, nil] unless candidate
      command = if candidate['action'] == 'draw'
        if state[:reaction]
          # Seal the reaction window before an irreversible server take. A
          # simultaneous safety can win this claim without consuming a card.
          GameRoomPrivateCards.command('draw_intent', '', operation: 'claim')
        else
          private_take_command(state, 'draw', 1)
        end
      else
        private_reveal_command(state, actor, candidate)
      end
      command ? [:ok, ActionPlan.new(events: [command])] : [:invalid, nil]
    end

    def private_automatic_command(state, action)
      case action
      when 'private_deal', 'private_recycle'
        fresh = action == 'private_deal'
        cards = fresh ? deck_for(state[:options]) : state[:discard]
        round = fresh ? state[:round] + 1 : state[:round]
        retire = private_retirable_pools(state, fresh: fresh)
        GameRoomPrivateCards.command(action, round.to_s, operation: 'create', size: cards.length, retire: retire)
      when 'private_ready'
        pool = state[:private_pools].fetch(state[:private_pool])
        GameRoomPrivateCards.command(action, state[:private_pool], operation: 'check',
          pool_id: state[:private_pool], size: pool[:cards].length)
      when 'initial_hand' then private_take_command(state, action, 6)
      when 'bonus_draw' then private_take_command(state, action, 1)
      when 'draw' then private_take_command(state, action, 1)
      end
    end

    def private_take_command(state, action, count)
      GameRoomPrivateCards.command(action, '', operation: 'take', pool_id: state[:private_pool], count: count)
    end

    def private_reveal_command(state, actor, candidate)
      receipt = GameRoomPrivateCardLedger.locate(state, actor, candidate['card'])
      return nil unless receipt
      request = GameRoomPrivateCardLedger.known?(state, receipt) ? {operation:'claim'} : receipt.merge(operation:'reveal')
      GameRoomPrivateCards.command(candidate['action'], action_value(candidate), **request)
    end
  end
end
