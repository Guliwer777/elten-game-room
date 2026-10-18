require_relative '../../lib/game_room_localization'

module GameRoomGames
  using GameRoomLocalization::Translations
  class Uno
    Play = Struct.new(:card, :choice, :deadline, :previous_current_player, :current, :straight, :interception, :player, :awaiting_colour, :selected_seven_target, :late, keyword_init: true)

    module PlayReduction
      private

      def validated_play(state, event, actor)
        card, choice, deadline_text = event["value"].to_s.split("|", 3)
        deadline = deadline_text.to_i
        return nil if colour_choice_pending?(state)

        previous_current_player = state[:current_player]
        current = same_user?(actor, state[:current_player])
        straight = !current && straight_continuation?(state, actor, card)
        interception = !current && !straight && state[:options]["interceptions"] && interceptable?(state, card)
        return nil if state[:phase] != :playing || state[:buzzer_active]
        player = player_key(state, actor)
        return nil if player == nil || !active_players(state).include?(player) || !state[:hands][player].include?(card)
        if !current && !interception && !straight
          return nil if !too_late_interception?(state, player, card)

          return Play.new(player: player, late: true)
        end
        return nil if current && !playable?(state, card)
        awaiting_colour = wild?(card) && !buzzer?(card) && choice.to_s.empty?
        if wild?(card) && !buzzer?(card) && !awaiting_colour
          return nil if !available_colors(state).include?(choice)
        end
        selected_seven_target = nil
        if state[:options]["zero_seven"] && card_number(card) == 7
          selected_seven_target = seven_target(state, player, choice)
          return nil if selected_seven_target == nil
        end
        Play.new(card: card, choice: choice, deadline: deadline, previous_current_player: previous_current_player, current: current, straight: straight, interception: interception, player: player, awaiting_colour: awaiting_colour, selected_seven_target: selected_seven_target)
      end

      def apply_late_play(state, event, player, repository, history)
        # Resolve the attempt against the ordered replay, not the old screen:
        # a preceding human/bot play may have changed the interception target.
        state[:scores][player] += 3
        id = repository.event_id(event)
        history << HistoryEntry.new(key: "too_late:#{id}",
          text: _("Too late!"),
          event_id: id, actor: player, kind: :score, value: 3)
        return true
      end

      def apply_play(state, event, actor, repository, history)
        play = validated_play(state, event, actor)
        return false unless play
        if play.late
          return apply_late_play(state, event, play.player, repository, history)
        end
        card, choice, deadline, previous_current_player, current, straight, interception, player, awaiting_colour, selected_seven_target = play.to_a
        clear_straight(state) if current || interception
        played_text = awaiting_colour ? uno_label(card, state) : played_label(card, choice, state)
        state[:hands][player].delete_at(state[:hands][player].index(card))
        previous_colour = state[:colour]
        state[:discard] << card
        state[:colour] = if awaiting_colour
          nil
        elsif wild?(card)
          buzzer?(card) ? nil : choice
        else
          card_color(card)
        end
        state[:free_play] = false
        state[:optional_draws] = 0
        state[:uno_window] = nil
        (state[:uno_declarations] ||= {}).delete(player)
        state[:challenge_player] = state[:challenge_legal] = state[:challenge_source] = nil
        type = card_type(card)
        penalty = draw_penalty(state, card)
        responding_to_penalty = state[:pending_draw] > 0
        if penalty > 0
          state[:pending_draw] += penalty
          state[:pending_type] = type
          state[:pending_family] = penalty_family(state, card)
          state[:pending_strength] = penalty
        end
        if type == "C"
          state[:pending_type] = "C"
          state[:pending_colour] = choice if !awaiting_colour
          state[:pending_family] = nil
        end
        if challenge_card?(state, card) && state[:options]["bluff_challenge"]
          state[:challenge_player] = if awaiting_colour
            nil
          else
            interception ? previous_current_player : next_active_player(state, player, 1)
          end
          state[:challenge_source] = player
          state[:challenge_legal] = challenge_legality(state, player, previous_colour)
        end
        if type == "A"
          discarded = discard_colour_cards(state, player, card_color(card))
          state[:hands][player] -= discarded
          state[:discard].insert(state[:discard].length - 1, *discarded)
        end
        id = repository.event_id(event)
        play_key = interception ? "interception" : (straight ? "straight" : "play")
        history << HistoryEntry.new(key: "#{play_key}:#{id}", text: _("%{player} played %{card}.") % { player: participant_name(player), card: played_text }, event_id: id, actor: actor, kind: :play)
        if type == "L"
          flip_all_cards(state)
          side = state[:side] == :dark ? _("dark side") : _("light side")
          history << HistoryEntry.new(key: "flip:#{id}", text: _("Flip: %{side}. %{top}") % { side: side, top: top_text(state) }, event_id: id, actor: actor, kind: :game)
        end
        if type == "A" && !discarded.empty?
          text = n_("%{player} also discards %{count} %{colour} card.", "%{player} also discards %{count} %{colour} cards.", discarded.length) % { player: participant_name(player), count: discarded.length, colour: COLOR_NAMES.fetch(card_color(card)) }
          history << HistoryEntry.new(key: "discard_colour:#{id}", text: text, event_id: id, actor: actor, kind: :game)
        end
        cancels_penalty = responding_to_penalty && state[:options]["advanced_responses"] && %w[A E].include?(type)
        clear_pending_penalty(state) if cancels_penalty
        steps = type == "S" && !responding_to_penalty ? 2 : 1
        steps = 0 if type == "E" && !responding_to_penalty
        if type == "V"
          state[:direction] *= -1 if active_players(state).length > 2
          steps = active_players(state).length == 2 && !responding_to_penalty ? 2 : 1
        end
        if type == "R"
          state[:direction] *= -1
          steps = active_players(state).length == 2 ? 0 : 1
        end
        if awaiting_colour
          state[:colour_choice_player] = player
          state[:colour_choice_card] = card
          state[:colour_choice_steps] = steps
        end
        state[:current_player] = if awaiting_colour
          player
        elsif straight
          previous_current_player
        elsif interception && state[:pending_draw] > 0
          previous_current_player
        else
          next_active_player(state, player, interception ? 0 : steps)
        end
        if state[:options]["zero_seven"] && card_number(card) == 7
          target = selected_seven_target
          state[:hands][player], state[:hands][target] = state[:hands][target], state[:hands][player]
          history << HistoryEntry.new(key: "swap:#{id}", text: _("%{first} exchanged hands with %{second}.") % { first: participant_name(player), second: participant_name(target) }, event_id: id, actor: actor, kind: :game)
        elsif state[:options]["zero_seven"] && card_number(card) == 0
          rotated = active_players(state).map { |owner| state[:hands][owner] }
          active_players(state).each_with_index { |owner, index| state[:hands][owner] = rotated[(index - state[:direction]) % rotated.length] }
          text = state[:direction] == 1 ? _("All active players pass their hands to the next player in seating order.") : _("All active players pass their hands to the previous player in seating order.")
          history << HistoryEntry.new(key: "rotate:#{id}", text: text, event_id: id, actor: actor, kind: :game)
        end
        if buzzer?(card)
          state[:buzzer_active] = true
          state[:buzzer_pressed] = {}
          state[:buzzer_player] = player
          state[:turn_deadline] = 0
        elsif awaiting_colour
          state[:turn_deadline] = 0
        else
          state[:turn_deadline] = deadline if !straight
        end
        if state[:options]["zero_seven"] && [0, 7].include?(card_number(card))
          state[:uno_declarations] = {}
        end
        state[:uno_window] = player if state[:hands][player].length == 1
        if straight
          extend_straight(state, player, card)
        elsif current
          begin_straight(state, player, card)
        end
        finisher = active_players(state).find { |owner| state[:hands][owner].empty? }
        if finisher
          if state[:pending_draw] > 0 || state[:pending_colour] != nil || state[:buzzer_active] || colour_choice_pending?(state)
            state[:pending_finisher] ||= finisher
          else
            finish_round(state, finisher, id, history)
            return true
          end
        else
          apply_no_mercy(state, player, id, history, deadline: deadline)
        end
        finish_pending_round(state, id, history) if state[:phase] == :playing
        true
      end

      def challenge_legality(state, player, previous_colour)
        !state[:hands][player].any? { |candidate| !wild?(candidate) && card_color(candidate) == previous_colour }
      end

      def discard_colour_cards(state, player, colour)
        state[:hands][player].select { |candidate| card_color(candidate) == colour }
      end
    end

    include PlayReduction
  end
end
