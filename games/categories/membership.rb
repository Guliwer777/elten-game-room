module GameRoomGames
  using GameRoomLocalization::Translations
  class Categories
    # Keep original seats and historical actors immutable. Only the roster
    # eligible for subsequent questions/judging shrinks.
    def membership_action(replay, members:, table_owner:)
      state = replay.state
      return nil if replay.finished? || state[:phase] == :interrupted || !members
      absent = remaining_players(state).reject { |player| includes_player?(members, player) }
      judge_missing = state[:options]['judge_mode'] == JUDGE_MASTER &&
        !includes_player?(members, state[:permanent_judge])
      return nil if absent.empty? && !judge_missing
      surface_action('membership', 'remove', 'players' => absent,
        'judge' => table_owner.to_s, 'judge_left' => judge_missing, 'attempt' => state[:attempt])
    end

    def interruption_reason(replay)
      'not_enough_players' if replay.state[:phase] == :interrupted
    end

    def interruption_message
      _("The game was interrupted because fewer than two participants remain.")
    end

    def eliminated_from_game?(replay, viewer)
      includes_player?(replay.state[:departed_players], viewer)
    end

    def tournament_active_players(replay, options:)
      remaining_players(replay.state)
    end

    def tournament_forfeit_continuation(replay, losing_unit:, options:)
      return {'status'=>'unsupported'} unless tournament_competitive_roster?(player_count:replay.players.length, options:options) &&
        %i[setup answering revealing review round_complete].include?(replay.state[:phase])
      active = remaining_players(replay.state)
      return {'status'=>'unsupported'} unless includes_player?(active, losing_unit)

      {'status'=>active.length > 2 ? 'continue' : 'cannot_continue'}
    end

    def moderator_action?(selection)
      selection['kind'] == 'review' || super
    end

    private

    def remaining_players(state)
      state[:players].reject { |player| includes_player?(state[:departed_players], player) }
    end

    def remaining_contestants(state)
      remaining_players(state).reject do |player|
        state[:options]['judge_mode'] == JUDGE_MASTER && same_user?(player, state[:permanent_judge])
      end
    end

    def reviewing_actor?(state, actor, authority = nil)
      same_user?(state[:judge], actor) ||
        (owner?(state[:players], actor) && !authority.to_s.empty? && same_user?(state[:judge], authority))
    end

    def membership_plan(selection, state, actor, context)
      return [:not_your_turn, nil] unless owner?(state[:players], actor) && context &&
        selection['action'] == 'remove' && selection['attempt'] == state[:attempt] &&
        same_user?(selection['judge'], context.table_owner)
      names = selection['players']
      return [:invalid, nil] unless names.is_a?(Array) && names.uniq == names &&
        names.all? { |player| includes_player?(remaining_players(state), player) }
      seats = names.map { |player| state[:players].index(player) }
      # The action value has a 64-character wire limit. The authenticated
      # controller already supplies the judge's identity; encode only seats
      # and the attempt, never repeat account names in this value.
      data = [state[:attempt], seats, selection['judge_left'] == true]
      [:ok, event_plan('participants_departed', JSON.generate(data))]
    end

    def reduce_participants_departed(frame, input)
      state = frame.state
      return false if [:finished, :interrupted].include?(state[:phase]) || !owner?(frame.players, input.actor)
      # The existing native controller ledger authenticates this authority at
      # the event's stack position, not at the time of a later replay.
      source = input.source
      authority = source['__authority_user'].to_s
      return false unless source['__controller'] == true && !authority.empty? &&
        same_user?(source['__insertion_user'], authority)
      data = JSON.parse(input.value)
      return false unless data.is_a?(Array) && data.length == 3 &&
        data[0] == state[:attempt] && [true, false].include?(data[2])
      seats = data[1]
      return false unless seats.is_a?(Array) && seats.uniq == seats && seats.all? do |seat|
        seat.is_a?(Integer) && seat.between?(0, frame.players.length - 1) &&
          !includes_player?(state[:departed_players], frame.players[seat])
      end
      departed = seats.map { |seat| frame.players.fetch(seat) }
      permanent = state[:options]['judge_mode'] == JUDGE_MASTER
      judge_departed = includes_player?(departed, state[:judge]) ||
        (permanent && data[2])
      return false if departed.empty? && !judge_departed
      apply_departed_players(frame, input, departed:departed, judge_departed:judge_departed, authority:authority)
    rescue JSON::ParserError
      false
    end

    def reduce_tournament_elimination(frame, input)
      state = frame.state
      departed = tournament_elimination_players(input.source, players:frame.players)
      return false unless departed && !departed.empty? &&
        departed.all? { |player| tournament_forfeit_continuation(Replay.new(players:frame.players, state:state),
          losing_unit:player, options:frame.options)['status'] == 'continue' } &&
        (remaining_players(state) - departed).length >= 2

      (state[:tournament_eliminations] ||= []) << departed
      apply_departed_players(frame, input, departed:departed,
        judge_departed:includes_player?(departed, state[:judge]), authority:nil)
    end

    def apply_departed_players(frame, input, departed:, judge_departed:, authority:)
      state = frame.state
      permanent = state[:options]['judge_mode'] == JUDGE_MASTER
      old_groups = review_items(state)
      old_decisions = state[:decisions].dup
      unfinished = [:answering, :revealing, :review].include?(state[:phase])
      rollback_incomplete_scores(state) if unfinished
      state[:departed_players].concat(departed)
      state[:roster_revision] += 1
      state[:judge_queue] -= departed
      state[:tie_break_players]&.reject! { |player| includes_player?(departed, player) }
      state[:permanent_judge] = authority if permanent && judge_departed
      departed.each do |player|
        frame.history << history_entry(input.id,
          _("%{player} left this game.") % {player: participant_name(player)}, player, :departure)
      end
      if unfinished
        HiddenSubmissions::Cleanup.confirm(state, round_id(state), state[:commitments].select do |player, _|
          includes_player?(departed, player)
        end)
        state[:active_players] -= departed
        %i[commitments reveals reveal_parts].each do |key|
          state[key].delete_if { |player, _| includes_player?(departed, player) }
        end
        state[:decisions] = review_items(state).each_with_object({}) do |item, preserved|
          before = old_groups.find { |group| group[:id] == item[:id] }
          decision = old_decisions[item[:id]]
          if before && before[:players] == item[:players] && review_decision_allowed?(item, decision)
            preserved[item[:id]] = decision
          end
        end
        state[:review_finished] = false unless state[:decisions].length == review_items(state).length
      end
      if state[:final_end_round] && state[:options]['judge_mode'] == JUDGE_ROTATING
        remaining = state[:tie_break_players].to_a.empty? ? state[:judge_queue].length :
          [state[:final_end_round] - state[:completed_rounds], state[:judge_queue].length].min
        state[:final_end_round] = state[:completed_rounds] + remaining
      end
      available = remaining_players(state)
      available |= [state[:permanent_judge]] if permanent
      if available.length < minimum_players
        HiddenSubmissions::Cleanup.confirm(state, round_id(state), state[:commitments])
        state[:phase] = :interrupted
        state[:deadline] = 0
        frame.history << history_entry(input.id, scores_text(state, sorted: true), '', :final_scores)
      elsif unfinished && judge_departed
        HiddenSubmissions::Cleanup.confirm(state, round_id(state), state[:commitments])
        state[:phase] = :round_complete
        state[:deadline] = 0
        state[:resume_at] = input.timestamp.to_i + NEXT_ROUND_PAUSE
        state[:active_players] = []
        %i[commitments reveals reveal_parts decisions].each { |key| state[key] = {} }
        state[:review_finished] = false
        frame.history << history_entry(input.id,
          _("The judge left. This round was cancelled; a new round will begin."), '', :round_cancelled)
      end
      if state[:phase] == :round_complete && state[:final_end_round] && state[:final_end_round] <= state[:completed_rounds]
        frame.winner, frame.draw = update_match_ending(state, frame.history, input.id)
        state[:phase] = :finished if frame.winner || frame.draw
      end
      true
    end

    def rollback_incomplete_scores(state)
      state[:round_scores].each { |player, points| state[:scores][player] -= points }
      state[:round_scores] = {}
    end
  end
end
