module GameRoomGames
  class Base
    module Tournaments
      class InvalidResult < ArgumentError; end
      def tournament_private_protocol?; false; end

      # New plans require every assigned seat to compete for the result.
      # Games with a permanent non-competing judge can reject that mode.
      def tournament_competitive_roster?(player_count:, options: {}); true; end

      # Some ordinary game protocols bind moderation to a particular seat.
      # Nil leaves the existing deterministic coordinator selection in place.
      def tournament_table_creator_seat(options:, player_count:); nil; end

      # Persisting events through the runner does not imply turn-based play.
      # A game with realtime physics declares its required execution client.
      def tournament_execution_kind
        session_runner? ? :turn_based : :realtime
      end

      # A declared command/result protocol, never a list of game identifiers.
      # Unknown team protocols remain closed until their executor is connected.
      def tournament_fixed_team_protocol
        return 'game-owned-turn-actions-v1' if tournament_execution_kind == :turn_based
        'game-owned-realtime-actions-v1' if tournament_execution_kind == :realtime && tournament_realtime_point_action.is_a?(String)
      end

      def tournament_fixed_team_actions?
        case tournament_fixed_team_protocol
        when 'game-owned-turn-actions-v1' then tournament_execution_kind == :turn_based
        when 'game-owned-realtime-actions-v1'
          tournament_execution_kind == :realtime && tournament_realtime_point_action.is_a?(String)
        else false
        end
      end

      # Inherited by future games; there is no tournament game-id allowlist.
      def tournament_capabilities(options: {})
        normalized = normalize_options(options)
        counts = (minimum_players..maximum_players).select do |count|
          validation_error(normalized, player_count: count).nil?
        end
        {version: 1, player_counts: counts.freeze,
          execution: tournament_execution_kind}.freeze
      end

      def tournament_result(replay, options: {})
        raise InvalidResult, 'The game has not finished' unless replay && replay.finished?
        players = replay.players.to_a
        raise InvalidResult, 'Invalid participants' if players.empty? || GameRoomParticipants.unique(players).size != players.size
        normalized = normalize_options(options)
        assignment = prepared_team_assignment(normalized, players: players)
        if team_size(normalized, player_count: players.size).positive? && !assignment
          raise InvalidResult, 'Missing confirmed team assignment'
        end
        units = assignment ? assignment.team_ids.to_h { |id| [id, assignment.members_for(id)] } : players.to_h { |player| [player, [player]] }
        winner = units.keys.find { |id| GameRoomParticipants.same?(id, replay.winner) } unless replay.winner.nil?
        raise InvalidResult, 'Unknown winning unit' if !replay.winner.nil? && !winner
        raise InvalidResult, 'Conflicting outcome' if winner && replay.draw == true
        scores = tournament_scores(replay, options: normalized)
        unless scores.nil? || (scores.is_a?(Hash) && scores.keys.sort == units.keys.sort &&
            scores.values.all? { |score| score.is_a?(Integer) || (score.is_a?(Float) && score.finite?) })
          raise InvalidResult, 'Invalid game scores'
        end
        {units: units.transform_values { |members| members.map { |name| name.dup.freeze }.freeze }.freeze,
          winners: (winner ? [winner.dup.freeze] : []).freeze, draw: replay.draw == true,
          scores: scores && scores.dup.freeze}.freeze
      end

      def tournament_roles(player_count:, options: {})
        unless tournament_capabilities(options: options)[:player_counts].include?(player_count)
          raise InvalidResult, 'Unsupported match size'
        end
        Array.new(player_count) { |seat| "seat:#{seat}".freeze }.freeze
      end

      def tournament_role_policy(player_count:, options: {})
        # Preserve the existing two-seat plan format when reading old records.
        player_count == 2 ? 'local-test-board-seats-explicit-reverse-v1' : 'local-test-individual-seats-explicit-reverse-v1'
      end

      # Optional game-owned hook. No score is inferred from private state fields.
      def tournament_scores(_replay, options:); nil; end

      # New accepted plans opt into this export; old receipts retain the old
      # tournament_scores contract. Games declare their own scoring semantics.
      def tournament_export_scores(replay, options:)
        tournament_scores(replay, options: options)
      end

      # Explicit ordered small points for new result policies. Keep the
      # earlier score export unchanged when reading historical receipts.
      def tournament_export_small_scores(replay, options:)
        {scores: tournament_export_scores(replay, options: options), order: 'higher'}
      end

      # Explicit agreed-point input for the existing realtime client. A future
      # game can opt in without changing tournament code or an ID allowlist.
      def tournament_realtime_point_action; nil; end

      def tournament_export_result(replay, options:)
        tournament_result(replay, options: options)
      end

      # Current exports can distinguish more than a single winner. Separate
      # hooks keep previously accepted plans reproducible under their policy.
      def tournament_ranking_result(replay, options:)
        tournament_export_result(replay, options: options)
      end

      def tournament_ranking_scores(replay, options:)
        tournament_export_small_scores(replay, options: options)
      end

      # Opt-in for games that publicly name all winning people, rather than
      # a team id. Require whole confirmed teams; never infer private winners.
      def tournament_result_from_public_winners(replay, options:, winners:)
        raise InvalidResult, 'The game has not finished' unless replay && replay.finished?
        players = replay.players.to_a
        normalized = normalize_options(options)
        assignment = prepared_team_assignment(normalized, players: players)
        if team_size(normalized, player_count: players.size).positive? && !assignment
          raise InvalidResult, 'Missing confirmed team assignment'
        end
        units = assignment ? assignment.team_ids.to_h { |id| [id, assignment.members_for(id)] } : players.to_h { |name| [name, [name]] }
        unless winners.is_a?(Array) && !winners.empty? && GameRoomParticipants.unique(winners).size == winners.size &&
            winners.all? { |name| GameRoomParticipants.includes?(players, name) }
          raise InvalidResult, 'Invalid public winning participants'
        end
        winning_units = units.keys.select { |id| units[id].all? { |name| GameRoomParticipants.includes?(winners, name) } }
        unless winning_units.sum { |id| units[id].size } == winners.size && replay.draw != true
          raise InvalidResult, 'Incomplete winning team'
        end
        {units: units, winners: winning_units, draw: false, scores: nil}
      end

      # Opt-in helper for games whose public participant score repeats the
      # team's total. Collapse it once per team, never sum repeated totals.
      def tournament_public_unit_scores(replay, options:)
        players = replay.players.to_a
        scores = participant_scores(replay)
        unless scores.is_a?(Hash) && scores.keys.sort == players.sort
          raise InvalidResult, 'Invalid public participant scores'
        end
        assignment = prepared_team_assignment(normalize_options(options), players: players)
        units = assignment ? assignment.team_ids.to_h { |id| [id, assignment.members_for(id)] } : players.to_h { |name| [name, [name]] }
        units.to_h do |id, members|
          values = members.map { |name| scores.fetch(name) }
          raise InvalidResult, 'Conflicting public team scores' unless values.uniq.size == 1
          [id, values.first]
        end
      end

      # Reuse the game's existing, translated surface labels in tournament UI.
      def tournament_move_label(selection, replay:, viewer:)
        if selection['kind'] == 'card'
          spec = surface_spec(replay, viewer)
          zone = spec.zones.find { |item| item.id.to_s == selection['zone'].to_s } if spec.respond_to?(:zones)
          card = zone && zone.cards.find { |item| item.id.to_s == selection['card'].to_s }
          return card.label if card
        elsif selection['kind'] == 'tile' && selection.key?('tile')
          spec = surface_spec(replay, viewer)
          tile = spec.zones.flat_map(&:cards).find { |item| item.id.to_s == selection['tile'].to_s } if spec.respond_to?(:zones)
          if tile
            choice = tile.choices.to_a.find { |item| item.id.to_s == selection['target'].to_s }
            return choice ? [tile.label, choice.label].join(', ') : tile.label
          end
        elsif selection['kind'] == 'grid' && respond_to?(:field_label, true)
          return field_label(selection['x'], selection['y'])
        end
        selection['label'] || selection['action']
      end
    end
    include Tournaments
  end
end
