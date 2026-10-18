require_relative 'private_card_game'
require_relative 'game_snapshot'

# A selection spanning several native receipts is one logical move. Prove
# only its selected cards, then run the unchanged rule applicator once.
module GameRoomPrivateCardSelection
  include GameRoomPrivateCardGame

  private

  def private_secure_plan(plan, state, actor)
    normalized = private_normalize_plan(plan, state)
    return super unless normalized && normalized.events.one?
    event = normalized.events.first
    cards = private_event_cards({'action'=>event.action, 'value'=>event.value}, state) - state[:private_public]
    receipts = cards.map { |card| GameRoomPrivateCardLedger.locate(state, actor, card) }
    return [:invalid, nil] if receipts.any?(&:nil?)
    return super if receipts.map { |receipt| receipt[:draw_id] }.uniq.size <= 1 &&
      (receipts.none? { |receipt| GameRoomPrivateCardLedger.known?(state, receipt) } ||
       receipts.all? { |receipt| GameRoomPrivateCardLedger.known?(state, receipt) })
    [:ok, GameRoomGames::ActionPlan.new(events: [GameRoomPrivateCards.command(event.action, event.value, operation:'claim')])]
  end

  def apply_replay_event(state, event, session, repository, history, *args)
    if state[:private_cards] && !private_waiting?(state) && !event['__server_pool']
      actor = repository.actor_of(event, session)
      cards = private_event_cards(event, state)
      return false unless cards.is_a?(Array) && cards.all? { |card| card.is_a?(String) || card.is_a?(Integer) } && cards.uniq == cards
      unless (cards - state[:private_public]).empty?
        return false unless private_selection_preflight?(state, event, actor)
        state[:private_pending_selection] = event
        GameRoomPrivateCardDisclosure.prepare(state, [actor], purpose:'action', cards:{actor=>cards})
        return true
      end
    end
    super
  end

  def private_selection_preflight?(state, _event, actor)
    state[:phase] == :playing && same_user?(state[:current_player], actor)
  end

  def private_disclosure_completed(state, purpose, event, session, repository, history)
    return super unless purpose == 'action'
    pending = state.delete(:private_pending_selection)
    return unless pending
    candidate, additions = GameRoomSnapshot.copy(state), []
    if apply_replay_event(candidate, pending, session, repository, additions)
      state.replace(candidate)
      history.concat(additions)
    end
  end
end
