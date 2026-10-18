require_relative '../lib/private_card_ledger'

GameRoomPrivateCards.register('taboo', host: %w[private_deal], payload: true, retain_unrevealed_draws: true,
  claim: %w[taboo private_ready taboo_repeat], take: %w[taboo_draw], reveal: %w[taboo_show],
  random: %w[taboo], deals: %w[deal], host_payload_actions: GameRoomGames::Taboo::MODERATOR_ACTIONS)

module GameRoomGames
  # Private tournament phrases use the shared account-owned pool ledger.
  # Public state stores opaque slots, not phrase indices or a deck seed.
  module TabooPrivate
    using GameRoomLocalization::Translations

    def initialize_private_taboo(state, session)
      GameRoomPrivateCardLedger.initialize_state(state, session)
      state.merge!(taboo_slots: {}, taboo_shared: session.fetch('__shared_draws', {}))
    end

    def private_draw_audiences(state)
      return {} unless state[:private_cards] && state[:phase] == :describing
      slot = state[:taboo_slots][state[:card]]
      return {} unless slot && slot[:draw]
      {slot[:draw] => {owner: slot[:owner], pool: slot[:pool], count: 1,
        size: cards(state).size, recipients: state[:teams][1 - state[:team]].dup}}
    end

    def automatic_action_allowed?(replay, actor, table_owner:)
      return super unless replay.state[:private_cards]
      same_user?(actor, table_owner) || replay.players.any? { |name| same_user?(name, actor) }
    end

    def automatic_actor(replay, viewer, table_owner:)
      return super unless replay.state[:private_cards]
      same_user?(viewer, table_owner) && !replay.players.include?(viewer) ? replay.players.first : viewer
    end

    def automatic_action(replay, actor, context: nil)
      state = replay.state
      return super unless state[:private_cards]
      return nil if state[:private_error]
      owner = context&.table_owner || state[:master]
      hosting = same_user?(state[:private_viewer], owner) &&
        (same_user?(actor, owner) || (!replay.players.include?(owner) && actor == replay.players.first))
      if same_user?(actor, state[:private_viewer])
        show = state[:taboo_slots].values.find do |slot|
          slot[:draw] && same_user?(slot[:owner], actor) && !private_taboo_value(state, slot, public_only: true) &&
            (slot[:turn] != state[:turn] || ![:preparing, :describing].include?(state[:phase]))
        end
        return {'action'=>'taboo_show', 'slot'=>show[:id]} if show
        pool = state[:private_pool]
        if !pool || state[:private_pools][pool][:remaining].zero?
          return {'action'=>'private_deal'} if hosting
          return nil
        end
        unless state[:private_ready].any? { |name| same_user?(name, actor) }
          return {'action'=>'private_ready'} if replay.players.include?(actor)
        end
        slot = state[:taboo_slots][state[:card]]
        if slot && same_user?(slot[:owner], actor) && state[:private_ready].size == replay.players.size
          return {'action'=>'taboo_draw', 'slot'=>slot[:id]} unless slot[:draw]
          previous = state[:taboo_slots][slot[:previous]]
          if slot[:first] && previous && private_taboo_value(state, slot) == private_taboo_value(state, previous)
            return {'action'=>'taboo_repeat', 'slot'=>slot[:id]}
          end
        end
      end
      return nil unless hosting
      pool = state[:private_pool]
      return {'action'=>'private_deal'} if !pool || state[:private_pools][pool][:remaining].zero?
      return nil if state[:phase] == :awaiting_deal && state[:private_ready].size != replay.players.size
      super(replay, replay.players.first, context: context)
    end

    def moderator_action?(selection)
      selection.to_h['action'] == 'private_deal' || super
    end

    def action_for(selection, replay, actor, context: nil)
      state = replay.state
      return super unless state[:private_cards]
      return [:invalid, nil] if state[:private_error]
      input = selection.to_h.transform_keys(&:to_s)
      action = input['action']
      if %w[private_deal private_ready taboo_draw taboo_show taboo_repeat].include?(action)
        expected = automatic_action(replay, actor, context: context)
        return [:invalid, nil] unless expected == input
        slot = state[:taboo_slots][input['slot']]
        command = case action
        when 'private_deal'
          GameRoomPrivateCards.command(action, state[:cycle].to_s, operation: 'create', size: cards(state).size,
            retire: GameRoomPrivateCardLedger.retirable_pools(state))
        when 'private_ready'
          GameRoomPrivateCards.command(action, state[:private_pool], operation: 'check',
            pool_id: state[:private_pool], size: cards(state).size)
        when 'taboo_draw'
          GameRoomPrivateCards.command(action, slot[:id], operation: 'take', pool_id: state[:private_pool], count: 1)
        when 'taboo_show'
          value = state[:private_values].fetch(slot[:draw]).first
          GameRoomPrivateCards.command(action, slot[:id], operation: 'reveal', pool_id: slot[:pool], draw_id: slot[:draw], value: value)
        else
          GameRoomPrivateCards.command(action, slot[:id], operation: 'claim')
        end
        return [:ok, ActionPlan.new(events: [command])]
      end
      # Keep the old moderator seat convention at the model boundary, while
      # native authentication always identifies the actual current host.
      model_actor = Taboo::MODERATOR_ACTIONS.include?(action) ? replay.players.first : actor
      result, plan = super(selection, replay, model_actor, context: context)
      return [result, plan] unless result == :ok && !GameRoomServerRandom.request_from(plan.events)
      commands = plan.events.map { |event| GameRoomPrivateCards.command(event.action, event.value, operation: 'claim') }
      [result, ActionPlan.new(events: commands)]
    end

    def apply_private_taboo(state, event, actor, host:)
      action, value = event.values_at('action', 'value')
      case action
      when 'private_deal'
        cycle, pool = value.to_s.split('|', -1)
        return false unless host && cycle == state[:cycle].to_s && GameRoomPrivateCards.pool_id?(pool) &&
          !state[:private_pools].key?(pool) && (!state[:private_pool] || state[:private_pools][state[:private_pool]][:remaining].zero?)
        state[:private_pool] = pool
        state[:private_pools][pool] = {cards: (0...cards(state).size).to_a, remaining: cards(state).size}
        state[:private_retired] |= GameRoomPrivateCardLedger.retirable_pools(state)
        state[:cycle] += 1
        state[:private_ready] = []
      when 'private_ready'
        return false unless state[:players].include?(actor) && value == state[:private_pool] && !state[:private_ready].include?(actor)
        state[:private_ready] << actor
      when 'taboo_draw'
        slot = state[:taboo_slots][value]
        return false unless slot && same_user?(slot[:owner], actor) && !slot[:draw] && state[:private_ready].include?(actor)
        return false unless GameRoomPrivateCardLedger.record_take(state, event, actor, count: 1)
        slot[:draw], slot[:pool] = event['__server_pool'].values_at('draw_id', 'pool_id')
        slot[:first] = event['__server_pool']['remaining'] == cards(state).size - 1
      when 'taboo_show'
        slot = state[:taboo_slots][value]
        proof = event['__server_pool']
        return false unless slot && same_user?(slot[:owner], actor) && proof && proof['operation'] == 'reveal' &&
          proof['draw_id'] == slot[:draw] && proof['pool_id'] == slot[:pool] &&
          (slot[:turn] != state[:turn] || ![:preparing, :describing].include?(state[:phase]))
        GameRoomPrivateCardLedger.observe_reveal(state, event, actor)
        return false unless private_taboo_value(state, slot, public_only: true)
        state[:private_draws][slot[:draw]][:used] = proof['values'].dup
        state[:taboo_slots].each_value do |entry|
          next unless entry[:repeat]
          left = private_taboo_value(state, entry, public_only: true)
          right = private_taboo_value(state, state[:taboo_slots][entry[:previous]], public_only: true)
          state[:private_error] = :invalid_repeat if left && right && left != right
        end
      when 'taboo_repeat'
        slot = state[:taboo_slots][value]
        return false unless slot && slot[:first] && slot[:previous] && !slot[:repeat] &&
          state[:card] == value && state[:phase] == :describing && same_user?(slot[:owner], actor)
        slot[:repeat] = true
        next_card(state)
      else
        return false
      end
      state[:revision] += 1
      true
    end

    def card_lines(state, viewer)
      return super unless state[:private_cards]
      return [] unless card_visible?(state, viewer) && same_user?(viewer, state[:private_viewer])
      value = private_taboo_value(state, state[:taboo_slots][state[:card]])
      return [] unless value
      card = cards(state)[value - 1]
      [card.fetch('word'), *card.fetch('forbidden')]
    end

    def surface_spec(replay, viewer)
      return super unless replay.state[:private_cards]
      state = replay.state
      if state[:private_error] || (state[:phase] == :review && !private_review_ready?(state))
        text = state[:private_error] ? _("The server deck is inconsistent. This game cannot continue.") : _("Waiting for players to reveal their cards.")
        return GameSurfaces::PawnTrackSpec.new(id: 'taboo_private_status', header: name,
          items: [GameSurfaces::PawnTrackItem.new(id: 'status', label: text)])
      end
      # The ordinary review UI receives only already authenticated public values.
      copy = clone_state(state)
      copy[:review].each { |entry| entry[:card] = private_taboo_value(state, state[:taboo_slots][entry[:card]], public_only: true) - 1 } if state[:phase] == :review
      super(replay.dup.tap { |value| value.state = copy }, viewer)
    end

    private

    def private_taboo_value(state, slot, public_only: false)
      return nil unless slot && slot[:draw]
      values = state[:private_known][slot[:draw]]
      values ||= state[:private_values][slot[:draw]] || state[:taboo_shared][slot[:draw]] unless public_only
      values&.first
    end

    def private_review_ready?(state)
      state[:taboo_slots].values.all? do |slot|
        !slot[:draw] || private_taboo_value(state, slot, public_only: true)
      end
    end

    def next_card(state)
      return super unless state[:private_cards]
      previous = state[:used].last
      state[:serial] += 1
      slot = "#{state[:turn]}:#{state[:serial]}"
      state[:taboo_slots][slot] = {id: slot, owner: state[:current_player], turn: state[:turn], previous: previous}
      state[:card] = slot
      state[:used] << slot
    end

    def apply(state, data, actor, event_id, history)
      return super unless state[:private_cards]
      action = data['action']
      return :invalid if state[:private_error]
      return :invalid if action == 'deal' && (!state[:private_pool] || state[:private_ready].size != state[:players].size)
      return :invalid if action == 'start' && !private_review_ready?(state)
      return :invalid if %w[correct skipped buzzed].include?(action) && !state[:taboo_slots][state[:card]]&.fetch(:draw, nil)
      return :invalid if %w[approve correct_result].include?(action) && !private_review_ready?(state)
      if action == 'correct_result'
        index = data['index']
        return :invalid unless index.is_a?(Integer) && index.between?(0, state[:review].size - 1)
        entry = state[:review][index]
        slot = entry[:card]
        entry[:card] = private_taboo_value(state, state[:taboo_slots][slot], public_only: true) - 1
        result = super
        entry[:card] = slot
        result
      else
        result = super
        if result == :ok && action == 'timeout'
          # Expiry can beat an in-flight take. Do not invent a neutral card
          # which was never displayed. A late receipt is still audited.
          state[:review].reject! { |entry| !state[:taboo_slots][entry[:card]][:draw] }
        end
        result
      end
    end
  end
  Taboo.prepend(TabooPrivate)
end

GameRoomPrivateCards.register_sharing('taboo') do |session, events, repository|
  game = GameRoomGames::Taboo.new
  game.private_draw_audiences(game.replay(session, events, repository).state)
end
