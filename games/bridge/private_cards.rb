require_relative '../../lib/private_card_game'
require_relative '../../lib/private_card_round_audit'

GameRoomPrivateCards.register('bridge', host: %w[private_deal],
  claim: %w[private_ready call], take: %w[initial_hand], reveal: %w[play], random: %w[deal])

module GameRoomGames
  module BridgePrivateCards
    include GameRoomPrivateCardGame

    private

    def private_event_card(event, _state)
      event['value'] if event['action'] == 'play'
    end

    # Dummy is a public hand after the opening lead, but declarer, not its
    # owner, chooses the card. The ordinary reducer still checks both seats.
    def private_event_hand_owner(state, event, actor)
      return actor unless event['action'] == 'play' && state[:phase] == :playing &&
        state[:dummy_visible] && state[:seat_to_play] == dummy_seat(state) &&
        same_user?(state[:current_player], actor)

      state[:seats][state[:seat_to_play]]
    end

    def private_deal_spec(state)
      GameRoomPrivateCardRoundAudit.begin_round(state)
      {hands: state[:hands], deck: BridgeRules::DECK}
    end

    def private_dealing_applied(state, _event, _session, _repository, _history)
      return unless state[:phase] == :bidding

      state[:private_initial_hands] = state[:hands].transform_values(&:dup)
    end

    # Scoring also needs the initial hands for honours and the HCP reference.
    # Do not write any partial score/rubber/result until the normal reducer
    # has verified the entire round against authenticated disclosed cards.
    def finish_deal(state, event_id, history)
      return super unless state[:private_cards]

      state[:private_finish_pending] = true
      state[:phase], state[:current_player] = :private_round_end, nil
    end

    def private_after_event(state, event, session, repository, history)
      state[:private_round_actions] << event
      if state[:private_finish_pending]
        waiting = GameRoomPrivateCardDisclosure.prepare(state, state[:players], purpose: 'board')
        private_finish_board(state, event, session, repository, history) unless waiting
      elsif event['action'] == 'play' && !state[:dummy_visible]
        owner = state[:seats][dummy_seat(state)]
        waiting = GameRoomPrivateCardDisclosure.prepare(state, [owner], purpose: 'dummy')
        reveal_dummy(state, repository.event_id(event), history) unless waiting
      end
    end

    def private_disclosure_completed(state, purpose, event, session, repository, history)
      case purpose
      when 'dummy'
        reveal_dummy(state, repository.event_id(event), history)
      when 'board'
        private_finish_board(state, event, session, repository, history)
      else
        super
      end
    end

    def private_finish_board(state, event, session, repository, history)
      audit = GameRoomPrivateCardRoundAudit.initial_state(state)
      audit_history = []
      if audit
        audit[:initial_hands] = audit[:seats].map { |player| audit[:hands].fetch(player).dup }
      end
      valid = audit && state[:private_round_actions].all? do |action|
        apply_replay_event(audit, action, session, repository, audit_history)
      end
      unless valid
        GameRoomPrivateCardRoundAudit.reject_round(state, event, repository, history)
        return
      end

      fields = [:scores, :rubber, :deals, :winner, :draw, :phase, :seat_to_play, :current_player, :initial_hands]
      state.merge!(audit.slice(*fields))
      state.delete(:private_finish_pending)
      audit_history.select { |entry| [:score, :result].include?(entry.kind) }.each do |entry|
        entry.event_id = repository.event_id(event)
        history << entry
      end
    end
  end
end
