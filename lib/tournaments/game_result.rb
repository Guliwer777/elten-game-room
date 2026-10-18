# encoding: UTF-8
require_relative 'publication'
require_relative '../game_event_protocol'
require_relative 'interrupted_outcome'

module GameRoomTournaments
  # Connects a game's public result contract to planned players/teams.
  # The caller owns history validation and the atomic receipt commit.
  class GameResult
    Data = Publication::Data
    SCORE_EXPORT_POLICY = 'game-owned-scores-v1'.freeze
    RESULT_EXPORT_POLICY = 'game-owned-result-v2'.freeze
    DRAW_RESULT_POLICY = 'game-owned-result-v3'.freeze
    SCORE_ORDER_POLICY = 'game-owned-result-v4'.freeze
    CURRENT_RESULT_POLICY = 'game-owned-result-v5'.freeze
    ORDERED_POLICIES = [SCORE_ORDER_POLICY, CURRENT_RESULT_POLICY].freeze
    RESULT_POLICIES = [RESULT_EXPORT_POLICY, DRAW_RESULT_POLICY, *ORDERED_POLICIES].freeze
    EXPORT_POLICIES = [SCORE_EXPORT_POLICY, *RESULT_POLICIES].freeze
    # Native history is a log of authenticated attempts, not only successful
    # rule transitions. A racing move may be ignored without invalidating a
    # later result. Keep the complete log (including irreversible reveals),
    # and verify that accepted transitions are its exact ordered subsequence.
    # The repository still owns authentication and server-proof validation.
    def self.valid_replay_history?(replay, events)
      return false unless replay && events.is_a?(Array) && replay.accepted_events.is_a?(Array)
      return false if replay.state.is_a?(Hash) && replay.state[:private_error]
      accepted = replay.accepted_events
      cursor = 0
      previous_id = 0
      events.each do |event|
        return false unless GameRoomEventProtocol.valid_wire_command?(event) &&
          event['actor'].is_a?(String) && !event['actor'].empty?
        id = event['__id'] || event['id']
        return false unless id.is_a?(Integer) && id > previous_id &&
          (!event.key?('__id') || !event.key?('id') || event['__id'] == event['id'])
        previous_id = id
        cursor += 1 if cursor < accepted.size && accepted[cursor] == event
      end
      cursor == accepted.size
    end

    def self.from_replay(game:, replay:, players:, options:, event_count:, result_policy: nil, events: nil)
      unless result_policy.nil? || EXPORT_POLICIES.include?(result_policy)
        raise Publication::Invalid, :invalid_game_result
      end
      history_valid = if events
        events.is_a?(Array) && event_count.is_a?(Integer) && event_count == events.size && valid_replay_history?(replay, events)
      else
        # Old callers/receipts without the original history remain strict.
        replay && replay.accepted_events.size == event_count &&
          !(replay.state.is_a?(Hash) && replay.state[:private_error])
      end
      unless replay && replay.finished? && history_valid &&
          replay.players.map { |name| Data.account(name).downcase }.sort == players.map { |p| p['account'] }.sort
        raise Publication::Invalid, :invalid_game_result
      end
      outcome = if result_policy==CURRENT_RESULT_POLICY
        game.tournament_ranking_result(replay,options:options)
      elsif RESULT_POLICIES.include?(result_policy)
        game.tournament_export_result(replay, options: options)
      else
        game.tournament_result(replay, options: options)
      end
      if RESULT_POLICIES.include?(result_policy)
        unless outcome.is_a?(Hash) && outcome[:units].is_a?(Hash) && outcome[:winners].is_a?(Array) &&
            outcome[:winners].uniq == outcome[:winners] && outcome[:winners].all? { |unit| outcome[:units].key?(unit) } &&
            [true, false].include?(outcome[:draw]) && (outcome[:draw] ? outcome[:winners].empty? : outcome[:winners].any?)
          raise Publication::Invalid, :invalid_game_result
        end
      end
      scores = outcome[:scores]
      score_order = nil
      unless result_policy.nil?
        if ORDERED_POLICIES.include?(result_policy)
          small = result_policy==CURRENT_RESULT_POLICY ? game.tournament_ranking_scores(replay,options:options) : game.tournament_export_small_scores(replay, options: options)
          unless small.is_a?(Hash) && small.keys.sort == [:order, :scores] && %w[higher lower].include?(small[:order])
            raise Publication::Invalid, :invalid_game_result
          end
          scores, score_order = small.values_at(:scores, :order)
        else
          scores = game.tournament_export_scores(replay, options: options)
        end
        unless scores.nil? || (scores.is_a?(Hash) && scores.keys.sort == outcome[:units].keys.sort &&
            scores.values.all? { |value| value.is_a?(Integer) || (value.is_a?(Float) && value.finite?) })
          raise Publication::Invalid, :invalid_game_result
        end
      end
      planned = players.group_by { |person| person['team'] || person['account'] }
      mapping = unit_mapping(units: outcome[:units], players: players)
      # An equal best result for every competing unit is a tournament draw.
      # Keep v2 archives byte-for-byte verifiable under their original policy.
      draw = outcome[:draw] || ([DRAW_RESULT_POLICY, *ORDERED_POLICIES].include?(result_policy) && outcome[:winners].size == planned.size)
      result = {'participants' => planned.keys.sort,
        'winners' => draw ? [] : outcome[:winners].map { |native| mapping.fetch(native) }, 'draw' => draw,
        'scores' => scores && scores.to_h { |native, score| [mapping.fetch(native), score] },
        'event_count' => event_count}
      result['score_order'] = score_order if score_order
      Data.freeze_tree(Data.copy(result))
    end

    # The same complete-roster mapping applies to a finished result and to a
    # game-owned scored checkpoint. Native side numbers are not plan unit IDs.
    def self.unit_mapping(units:, players:)
      planned = players.group_by { |person| person['team'] || person['account'] }
      mapping = units.to_h do |native, names|
        accounts = names.map { |name| Data.account(name).downcase }.sort
        units = players.select { |person| accounts.include?(person['account']) }.map { |p| p['team'] || p['account'] }.uniq
        unless units.size == 1 && planned.fetch(units.first).map { |p| p['account'] }.sort == accounts
          raise Publication::Invalid, :invalid_game_result
        end
        [native, units.first]
      end
      unless mapping.values.uniq.sort == planned.keys.sort && mapping.values.size == planned.size
        raise Publication::Invalid, :invalid_game_result
      end
      mapping
    end

    def self.roster_mapping(game:, replay:, options:, players:)
      assignment = game.prepared_team_assignment(game.normalize_options(options), players: replay.players)
      units = assignment ? assignment.team_ids.to_h { |unit| [unit, assignment.members_for(unit)] } :
        replay.players.to_h { |player| [player, [player]] }
      unit_mapping(units: units, players: players)
    end

    def self.checkpoint(game:, replay:, options:, players:)
      value = game.tournament_scored_checkpoint(replay, options: options)
      return value unless value.is_a?(Hash) && value['status'] == 'scored'
      mapping = roster_mapping(game: game, replay: replay, options: options, players: players)
      scores = value['scores']
      raise Publication::Invalid, :invalid_tournament_checkpoint unless scores.is_a?(Hash) && scores.keys.sort == mapping.keys.sort
      value.merge('scores'=>scores.to_h { |unit, score| [mapping.fetch(unit), score] })
    end

    def self.eliminations(replay, players:)
      groups = replay.state.is_a?(Hash) ? replay.state.fetch(:tournament_eliminations, []) : []
      return [] if groups.empty?
      raise Publication::Invalid, :invalid_game_result if players.any? { |person| person.key?('team') }
      normalized = groups.map { |group| group.map { |name| Data.account(name).downcase } }
      InterruptedOutcome.validate_eliminations(normalized, players.map { |person| person['account'] })
    end

    def self.with_eliminations(summary, groups)
      return summary if groups.empty?
      groups = InterruptedOutcome.validate_eliminations(groups, summary.fetch('participants'))
      active = summary['participants'] - groups.flatten
      winners = summary['draw'] ? active : summary.fetch('winners')
      raise Publication::Invalid, :invalid_game_result if winners.empty? || !(winners - active).empty?
      remaining = active - winners
      places = [winners.sort]
      if summary['scores']
        scores, order = summary.values_at('scores', 'score_order')
        places.concat(remaining.sort_by { |unit| order == 'lower' ? scores.fetch(unit) : -scores.fetch(unit) }.
          chunk_while { |left, right| scores.fetch(left) == scores.fetch(right) }.map(&:sort))
      elsif !remaining.empty?
        places << remaining.sort
      end
      Data.freeze_tree(Data.copy(summary.merge('winners'=>winners.sort, 'draw'=>false, 'places'=>places + groups.reverse)))
    end
  end
end
