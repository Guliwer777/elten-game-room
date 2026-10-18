require_relative 'private_card_dealing'
require_relative 'private_card_disclosure'

# Account-owned cards use the existing event applicators and session runner.
# Games declare their card boundaries, not another transport or scheduler.
module GameRoomPrivateCardGame
  using GameRoomLocalization::Translations

  def legal_actions(replay, actor, context: nil)
    # Rule applicators may enumerate public decisions to validate another
    # player's move. The viewer restriction belongs to input, not replay.
    return super if replay.state[:private_reducing]
    if replay.state[:private_cards]
      return [] if replay.state[:private_error] || private_waiting?(replay.state) ||
        !same_user?(actor, replay.state[:private_viewer])
    end
    actions = super
    if replay.state[:private_cards] && !same_user?(replay.state[:private_viewer], replay.state[:private_owner])
      actions = actions.reject { |action| GameRoomPrivateCards.deal_action?(id, action['action']) }
    end
    actions
  end

  def automatic_action_allowed?(replay, actor, table_owner:)
    return super unless replay.state[:private_cards]
    same_user?(actor, table_owner) || replay.players.any? { |player| same_user?(player, actor) }
  end

  def automatic_actor(replay, viewer, table_owner:)
    return super unless replay.state[:private_cards]
    [:private_wait, :private_dealing, :private_draw, :private_show, :private_effect].include?(replay.state[:phase]) ? viewer : super
  end

  def automatic_action(replay, actor, context: nil)
    return super unless replay.state[:private_cards]
    state = replay.state
    return nil if state[:private_error]
    action = GameRoomPrivateCardDealing.automatic(state, actor, owner: context&.table_owner)
    action = 'private_show' if GameRoomPrivateCardDisclosure.command(state, actor)
    if state[:phase] == :private_draw && same_user?(actor, state[:private_pending_draw][:actor]) &&
        same_user?(state[:private_viewer], actor)
      action = 'private_draw'
    end
    return {'kind' => 'command', 'action' => action} if action
    return nil if private_waiting?(state) || !same_user?(state[:private_viewer], context&.table_owner)
    super
  end

  def action_for(selection, replay, actor, context: nil)
    return super unless replay.state[:private_cards]
    state = replay.state
    return [:invalid, nil] if state[:private_error]
    automatic = automatic_action(replay, actor, context: context)
    if automatic && selection == automatic && private_waiting?(state)
      command = if selection['action'] == 'private_show'
        GameRoomPrivateCardDisclosure.command(state, actor)
      elsif selection['action'] == 'private_draw'
        draw = state[:private_pending_draw]
        request = {operation: 'take', pool_id: draw[:pool] || state[:private_pool], count: draw[:count]}
        request[:visibility] = 'public' if draw[:public]
        GameRoomPrivateCards.command('private_draw', draw[:purpose], **request)
      else
        GameRoomPrivateCardDealing.command(state, selection['action'], actor)
      end
      return [:ok, GameRoomGames::ActionPlan.new(events: [command])]
    end
    return [:invalid, nil] if private_waiting?(state)
    status, plan = super
    return [status, plan] unless status == :ok
    if (random = GameRoomServerRandom.request_from(plan.events))
      return [:not_your_turn, nil] unless same_user?(state[:private_viewer], state[:private_owner]) ||
        GameRoomPrivateCards.player_random?(id, random)
      return [status, plan]
    end
    private_secure_plan(plan, state, actor)
  end

  def private_secure_plan(plan, state, actor)
    plan = private_normalize_plan(plan, state)
    return [:invalid, nil] unless plan && plan.events.size == 1
    event = plan.events.first
    cards = private_event_cards({'action'=>event.action, 'value'=>event.value}, state)
    request = {operation: 'claim'}
    private_cards = cards - state[:private_public]
    if private_cards.any?
      receipts = private_cards.map { |card| GameRoomPrivateCardLedger.locate(state, actor, card) }
      return [:invalid, nil] if receipts.any?(&:nil?) || receipts.map { |receipt| receipt[:draw_id] }.uniq.size != 1
      first = receipts.first
      unless receipts.all? { |receipt| GameRoomPrivateCardLedger.known?(state, receipt) }
        request = first.merge(operation: 'reveal')
        request = first.reject { |key, _| key == :value }.merge(operation: 'reveal', values: receipts.map { |receipt| receipt[:value] }) if receipts.size > 1
      end
    end
    [:ok, GameRoomGames::ActionPlan.new(events: [GameRoomPrivateCards.command(event.action, event.value, **request)])]
  end
  private :private_secure_plan

  def incremental_replay(replay, session, events, repository)
    return nil if GameRoomPrivateCards.enabled?(session)
    super
  end

  def surface_spec(replay, viewer)
    state = replay.state
    return super unless state[:private_cards] && (state[:private_error] || private_waiting?(state))
    GameSurfaces::PawnTrackSpec.new(id: 'private_cards_status', header: name,
      items: [GameSurfaces::PawnTrackItem.new(id: 'status', label: private_status_text(state))])
  end

  def current_turn_shortcut_text(replay, viewer)
    state = replay.state
    return private_status_text(state) if state[:private_cards] && (state[:private_error] || private_waiting?(state))
    super
  end

  private

  def private_waiting?(state)
    [:private_prepare, :private_wait, :private_dealing, :private_draw, :private_show, :private_effect].include?(state[:phase])
  end

  def private_normalize_plan(plan, _state); plan; end
  def private_event_card(_event, _state); nil; end
  def private_event_cards(event, state); [private_event_card(event, state)].compact; end
  def private_event_hand_owner(_state, _event, actor); actor; end
  def private_reveal_positions(_state, _event, _actor); nil; end
  def private_deal_spec(state); {hands: state[:hands]}; end
  def private_after_event(_state, _event, _session, _repository, _history, *_args); end
  def private_received_cards(_state, _purpose, _cards, _event, _repository, _history); end
  def private_draw_completed(state, purpose, cards, event, session, repository, history)
    private_received_cards(state, purpose, cards, event, repository, history)
  end
  def private_dealing_applied(_state, _event, _session, _repository, _history); end
  def private_disclosure_completed(_state, _purpose, _event, _session, _repository, _history); end
  def private_disclosure_applied(_state, _event, _actor); end

  def turn_information_text(state)
    return private_status_text(state) if state[:private_error] || private_waiting?(state)
    super
  end

  def private_status_text(state)
    return _("The private deck has reached the server limit. This game cannot continue.") if state[:private_error] == :pool_limit
    return _("The server deck is inconsistent. This game cannot continue.") if state[:private_error]
    return _("Waiting for players to reveal their cards.") if state[:phase] == :private_show
    _("Waiting for all players to receive their cards.")
  end

  # A default draw follows the active deck after recycling. An explicit pool
  # is reserved for a stock ticket that intentionally addresses an older pool.
  def private_request_draw(state, actor:, count:, purpose:, public: true, pool: nil)
    state[:private_pending_draw] = {actor: actor, count: count, purpose: purpose,
      public: public, pool: pool, resume: [state[:phase], state[:current_player]]}
    state[:phase], state[:current_player] = :private_draw, nil
  end

  def apply_replay_event(state, event, session, repository, history, *args)
    return super unless state[:private_cards]
    actor = repository.actor_of(event, session)
    GameRoomPrivateCardLedger.observe_reveal(state, event, actor)
    return false if state[:private_error]
    action = event['action']
    if action == 'private_show'
      pending = state[:private_disclosure]
      return false unless state[:phase] == :private_show && pending
      disclosure = event['__server_pool'] ? event :
        GameRoomPrivateCardDisclosure.known_event(state, event, actor, pending[:purpose])
      return false unless disclosure && GameRoomPrivateCardDisclosure.apply(state, disclosure, actor)
      private_disclosure_applied(state, disclosure, actor)
      if GameRoomPrivateCardDisclosure.complete?(state)
        pending = state.delete(:private_disclosure)
        state[:phase], state[:current_player] = pending[:resume]
        private_completed_history(history, event, repository) do
          private_disclosure_completed(state, pending[:purpose], event, session, repository, history)
        end
      end
      return true
    end
    if %w[private_deal private_recycle private_ready initial_hand].include?(action)
      accepted = GameRoomPrivateCardDealing.apply(state, event, actor)
      if accepted
        private_completed_history(history, event, repository) do
          private_dealing_applied(state, event, session, repository, history)
        end
      end
      return accepted
    end
    if action == 'private_draw'
      pending = state[:private_pending_draw]
      return false unless state[:phase] == :private_draw && pending &&
        same_user?(actor, pending[:actor]) && event['value'] == pending[:purpose]
      cards = GameRoomPrivateCardLedger.record_take(state, event, actor, count: pending[:count], public: pending[:public],
        pool_id: pending[:pool] || state[:private_pool])
      return false unless cards
      state[:phase], state[:current_player] = pending[:resume]
      state[:private_pending_draw] = nil
      private_completed_history(history, event, repository) do
        private_draw_completed(state, pending[:purpose], cards, event, session, repository, history)
        private_after_event(state, event, session, repository, history, *args)
      end
      return true
    end
    return false if private_waiting?(state)
    cards = private_event_cards(event, state)
    accepted = if cards.any?
      hand_owner = private_event_hand_owner(state, event, actor)
      hand = state[:hands].find { |player, _| same_user?(player, hand_owner) }&.last
      hand && GameRoomPrivateCardLedger.with_cards(state, event, hand_owner, hand: hand, cards: cards,
        positions: private_reveal_positions(state, event, actor)) do
        private_reduce(state) { super }
      end
    else
      private_reduce(state) { super }
    end
    return false unless accepted
    if GameRoomPrivateCards.deal_action?(id, action)
      spec = private_deal_spec(state)
      GameRoomPrivateCardDealing.prepare(state, spec.fetch(:hands), **spec.reject { |key, _| key == :hands })
    else
      private_after_event(state, event, session, repository, history, *args)
    end
    true
  end

  def private_reduce(state)
    state[:private_reducing] = true
    yield
  ensure
    state.delete(:private_reducing)
  end

  # The rule action can finish on a later receipt. Present its new messages
  # with that receipt, not the earlier request whose transition had no result.
  # Stable message keys and every previously presented entry stay unchanged.
  def private_completed_history(history, event, repository)
    first = history.size
    result = yield
    history.drop(first).each { |entry| entry.event_id = repository.event_id(event) }
    result
  end
end
