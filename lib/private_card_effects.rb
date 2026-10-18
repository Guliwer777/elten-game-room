require_relative 'private_card_selection'

# A rule applicator may need an account-owned draw before it can finish a
# move. Re-run that same pure applicator with the received inputs; keep its
# table changes and announcements atomic. The normal runner writes every
# request. No game-specific network queue, thread or polling is introduced.
module GameRoomPrivateCardEffects
  include GameRoomPrivateCardSelection

  def automatic_action(replay, actor, context: nil)
    state = replay.state
    if state[:phase] == :private_effect && state[:private_effect]
      return nil if state[:private_error]
      request = state[:private_effect][:request]
      return nil unless [:boolean, :number].include?(request[:kind]) && same_user?(request[:actor], actor) &&
        same_user?(state[:private_viewer], actor)
      return {'kind'=>'command', 'action'=>'private_fact'}
    end
    super
  end

  def action_for(selection, replay, actor, context: nil)
    state = replay.state
    if state[:phase] == :private_effect && selection == automatic_action(replay, actor, context:context)
      effect = state[:private_effect]
      answer = effect[:request][:answer]
      return [:invalid, nil] unless private_fact_valid?(effect[:request], answer)
      value = effect[:request][:kind] == :boolean ? (answer ? 1 : 0) : answer
      event = GameRoomPrivateCards.command('private_fact', "#{effect[:key]}|#{effect[:inputs].size}|#{value}", operation:'claim')
      return [:ok, GameRoomGames::ActionPlan.new(events:[event])]
    end
    super
  end

  private

  def apply_replay_event(state, event, session, repository, history, *args)
    return super unless state[:private_cards] && event['action'] == 'private_fact'
    return false if state[:private_error]
    effect = state[:private_effect]
    return false unless state[:phase] == :private_effect && effect
    request = effect[:request]
    return false unless [:boolean, :number].include?(request[:kind]) && same_user?(request[:actor], repository.actor_of(event, session))
    key, index, answer = event['value'].to_s.split('|', -1)
    return false unless key == effect[:key] && index == effect[:inputs].size.to_s && /\A\d+\z/.match?(answer.to_s)
    return false if request[:kind] == :boolean && !%w[0 1].include?(answer)
    value = request[:kind] == :boolean ? answer == '1' : answer.to_i
    return false unless private_fact_valid?(request, value)
    return false if request.key?(:answer) && value != request[:answer]
    private_completed_history(history, event, repository) do
      private_complete_input(state, value, session, repository, history)
      private_after_event(state, event, session, repository, history, *args)
    end
    true
  end

  def private_apply_effect(state, event, session, repository, history)
    effect = state[:private_effect] ||= {event:event, key:repository.event_id(event).to_s,
      inputs:[], resume:[state[:phase], state[:current_player]]}
    candidate, additions = GameRoomSnapshot.copy(state), []
    candidate[:phase], candidate[:current_player] = effect[:resume]
    candidate[:private_effect_cursor] = 0
    result = catch(:private_card_input) do
      [:complete, private_reduce_effect(candidate, effect[:event], session, repository, additions)]
    end
    if result.first == :complete
      if result.last
        candidate.delete(:private_effect)
        candidate.delete(:private_effect_cursor)
        state.replace(candidate)
        history.concat(additions)
      else
        state.delete(:private_effect)
        state[:private_error] = :invalid_continuation unless effect[:inputs].empty?
      end
      return result.last
    end
    request = result.last
    effect[:request] = request
    state[:phase], state[:current_player] = :private_effect, nil
    case request[:kind]
    when :take
      args = request[:arguments].is_a?(Hash) ? request[:arguments] : {count:request[:arguments]}
      private_request_draw(state, actor:request[:actor], purpose:'effect', public:false, **args)
    when :recycle
      GameRoomPrivateCardDealing.recycle(state, request[:arguments], players:private_effect_players(state))
    when :hands
      state[:private_effect_hands] = request[:details]
      unless GameRoomPrivateCardDisclosure.prepare(state, request[:arguments][1],
          purpose:'effect', zone: :private_effect_hands)
        state.delete(:private_disclosure)
        private_complete_input(state, state.delete(:private_effect_hands), session, repository, history)
      end
    end
    true
  end

  def private_complete_input(state, value, session, repository, history)
    effect = state.fetch(:private_effect)
    effect[:inputs] << effect[:request].reject { |key, _| [:answer, :details].include?(key) }.merge(value:value)
    effect.delete(:request)
    private_apply_effect(state, effect[:event], session, repository, history)
  end

  def private_draw_completed(state, purpose, cards, event, session, repository, history)
    return super unless purpose == 'effect'
    private_complete_input(state, cards, session, repository, history)
  end

  def private_dealing_applied(state, event, session, repository, history)
    super
    if state[:phase] == :private_effect && state.dig(:private_effect, :request, :kind) == :recycle
      private_complete_input(state, state[:private_pool], session, repository, history)
      private_after_event(state, event, session, repository, history)
    end
  end

  def private_disclosure_completed(state, purpose, event, session, repository, history)
    return super unless purpose == 'effect'
    private_complete_input(state, state.delete(:private_effect_hands), session, repository, history)
    private_after_event(state, event, session, repository, history)
  end

  def private_effect_players(state); state[:players]; end

  def private_fact_valid?(request, value)
    return value == true || value == false if request[:kind] == :boolean
    request[:kind] == :number && value.is_a?(Integer) && value.between?(*request[:arguments].last(2))
  end

  # Inputs are consumed in the applicator's original order. A changed
  # request must not use a receipt or answer from another decision.
  def private_effect_input(state, kind, actor, arguments, details: nil)
    index = state[:private_effect_cursor]
    input = state[:private_effect][:inputs][index]
    key = {kind:kind, actor:actor, arguments:arguments}
    if input
      raise 'Private card continuation changed its input' unless input.slice(:kind, :actor, :arguments) == key
      state[:private_effect_cursor] += 1
      return GameRoomSnapshot.copy(input[:value])
    end
    if block_given? && same_user?(state[:private_viewer], actor) &&
        state[:hands].fetch(actor, []).none? { |card| GameRoomPrivateCardLedger.hidden?(card) }
      key[:answer] = yield
    end
    key[:details] = details if details
    throw :private_card_input, [:request, key]
  end

  def private_hand_decision(state, actor, name)
    return yield unless state[:private_cards] && state.key?(:private_effect_cursor)
    private_effect_input(state, :boolean, actor, name) { !!yield }
  end

  def private_hand_number(state, actor, name, range:)
    return yield unless state[:private_cards] && state.key?(:private_effect_cursor)
    private_effect_input(state, :number, actor, [name, range.begin, range.end]) { yield }
  end

  # Transfers and scoring use the game's existing hand operation only after
  # every affected account has proved those cards. Hands elsewhere stay secret.
  def private_disclose_hands(state, players, name, zone: :hands)
    return unless state[:private_cards]
    cards = players.to_h { |player| [player, state.fetch(zone).fetch(player).dup] }
    revealed = private_effect_input(state, :hands, nil, [name, players, zone], details:cards)
    revealed.each { |player, hand| state.fetch(zone)[player] = hand }
  end

  # Temporary packets (a face-up draw, a transfer or a penalty) use exactly
  # the same receipt disclosure as hands, without revealing the rest of a hand.
  def private_disclose_packet(state, actor, cards, name)
    state[:private_card_packet] = {actor=>cards.dup}
    private_disclose_hands(state, [actor], name, zone: :private_card_packet)
    state[:private_card_packet][actor]
  ensure
    state.delete(:private_card_packet)
  end

  def private_draw_from_stock(state, actor, count, stock: :draw_pile)
    result = []
    while result.size < count
      if state[stock].empty?
        cards = private_recyclable_cards(state)
        break if cards.empty?
        private_effect_input(state, :recycle, nil, cards)
        private_reset_stock(state, cards.size)
      end
      amount = [count - result.size, state[stock].size, 100].min
      cards = private_effect_input(state, :take, actor, amount)
      state[stock].shift(amount)
      result.concat(cards)
    end
    result
  end
end
