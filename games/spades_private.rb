require_relative '../lib/private_card_game'
require_relative '../lib/private_card_round_audit'

GameRoomPrivateCards.register('spades', host: %w[private_deal], claim: %w[private_ready bid],
  take: %w[initial_hand], reveal: %w[play], random: %w[deal])

module GameRoomGames
  module SpadesPrivate
    include GameRoomPrivateCardGame

    private

    def private_event_card(event, _state)
      event['value'] if event['action'] == 'play'
    end

    def private_deal_spec(state)
      GameRoomPrivateCardRoundAudit.begin_round(state)
      super
    end

    def private_after_event(state, event, session, repository, history, scoring)
      state[:private_round_actions] << event
      return unless [:round_complete, :finished].include?(state[:phase]) || state[:winner]
      audit = GameRoomPrivateCardRoundAudit.initial_state(state)
      valid = audit && state[:private_round_actions].all? do |item|
        apply_replay_event(audit, item, session, repository, [], scoring)
      end
      if valid
        remember_tournament_checkpoint(state, event_id: repository.event_id(event), index: state[:round], kind: 'deal')
      else
        GameRoomPrivateCardRoundAudit.reject_round(state, event, repository, history)
      end
    end
  end
end
