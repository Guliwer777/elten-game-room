require_relative '../lib/private_card_effects'

GameRoomPrivateCards.register('makao', host: %w[private_deal private_recycle],
  claim: %w[private_ready private_fact draw accept_skip makao catch pass makao_timeout],
  take: %w[initial_hand private_draw], reveal: %w[play], random: %w[deal])

module GameRoomGames
  module MakaoPrivate
    include GameRoomPrivateCardEffects

    def automatic_actor(replay, viewer, table_owner:)
      return viewer if replay.state[:private_cards] && replay.state[:phase] == :playing
      super
    end

    def automatic_action(replay, actor, context: nil)
      state = replay.state
      if state[:private_cards] && state[:phase] == :playing
        return nil unless same_user?(actor, state[:private_viewer]) && same_user?(actor, state[:current_player])
        return {'kind'=>'command', 'action'=>'makao_timeout'} if makao_deadline_reached?(state, context&.now)
        return forced_penalty_action(replay, actor)
      end
      super
    end

    def event_sound_cues(event:, before_replay:, after_replay:, history:, **args)
      return super unless after_replay.state[:private_cards]
      return nil if after_replay.state[:private_effect]
      action = history.any? { |entry| entry.kind == :play } ? 'play' :
        history.any? { |entry| entry.kind == :draw || entry.key.to_s.start_with?('catch:') } ? 'draw' : event['action']
      super(event:event.merge('action'=>action), before_replay:before_replay, after_replay:after_replay, history:history, **args)
    end

    private

    def makao_timeout_actor(state); state[:private_cards] ? state[:current_player] : super; end

    def private_event_cards(event, state)
      return [] unless event['action'] == 'play'
      GameRoomTurnClock.payload(state, event).split('|').first.to_s.split(',')
    end

    def private_deal_spec(state)
      deck = makao_deck(state[:options]['jokers']) - state[:discard]
      state[:draw_pile] = Array.new(deck.size - state[:hands].values.sum(&:size), :private_card)
      {hands:state[:hands], deck:deck}
    end

    def private_reduce_effect(state, event, session, repository, history)
      reduce_event(state, event, session, repository, history)
    end

    def private_after_event(state, _event, _session, _repository, _history)
      state[:private_public] |= state[:discard] unless state[:private_effect]
    end

    def draw_cards(state, count, player: nil)
      return super unless state[:private_cards]
      private_draw_from_stock(state, player, count.to_i)
    end

    def private_recyclable_cards(state); state[:discard][0...-1]; end

    def private_reset_stock(state, count)
      state[:discard] = state[:discard].last(1)
      state[:draw_pile] = Array.new(count, :private_card)
      state[:recycle] += 1
    end
  end
end
