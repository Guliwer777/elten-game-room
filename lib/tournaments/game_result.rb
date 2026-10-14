# encoding: UTF-8
require_relative 'publication'

module GameRoomTournaments
  # Connects a game's public result contract to planned players/teams.
  # The caller owns history validation and the atomic receipt commit.
  class GameResult
    Data = Publication::Data
    SCORE_EXPORT_POLICY = 'game-owned-scores-v1'.freeze
    RESULT_EXPORT_POLICY = 'game-owned-result-v2'.freeze
    DRAW_RESULT_POLICY = 'game-owned-result-v3'.freeze
    CURRENT_RESULT_POLICY = 'game-owned-result-v4'.freeze
    RESULT_POLICIES = [RESULT_EXPORT_POLICY, DRAW_RESULT_POLICY, CURRENT_RESULT_POLICY].freeze
    EXPORT_POLICIES = [SCORE_EXPORT_POLICY, *RESULT_POLICIES].freeze
    def self.from_replay(game:, replay:, players:, options:, event_count:, result_policy: nil)
      unless result_policy.nil? || EXPORT_POLICIES.include?(result_policy)
        raise Publication::Invalid, :invalid_game_result
      end
      unless replay && replay.finished? && replay.accepted_events.size == event_count &&
          replay.players.map { |name| Data.account(name).downcase }.sort == players.map { |p| p['account'] }.sort
        raise Publication::Invalid, :invalid_game_result
      end
      outcome = RESULT_POLICIES.include?(result_policy) ? game.tournament_export_result(replay, options: options) : game.tournament_result(replay, options: options)
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
        if result_policy == CURRENT_RESULT_POLICY
          small = game.tournament_export_small_scores(replay, options: options)
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
      mapping = outcome[:units].to_h do |native, names|
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
      # An equal best result for every competing unit is a tournament draw.
      # Keep v2 archives byte-for-byte verifiable under their original policy.
      draw = outcome[:draw] || ([DRAW_RESULT_POLICY, CURRENT_RESULT_POLICY].include?(result_policy) && outcome[:winners].size == planned.size)
      result = {'participants' => planned.keys.sort,
        'winners' => draw ? [] : outcome[:winners].map { |native| mapping.fetch(native) }, 'draw' => draw,
        'scores' => scores && scores.to_h { |native, score| [mapping.fetch(native), score] },
        'event_count' => event_count}
      result['score_order'] = score_order if score_order
      Data.freeze_tree(Data.copy(result))
    end
  end
end
