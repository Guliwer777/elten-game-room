require_relative 'spades_training'
require_relative '../../games/spades'
require 'json'
require 'time'

module GameRoomSpadesTools
  module_function

  def compare(arena, candidate, baseline, seeds, calibration: true)
    {
      head_to_head: arena.compare(candidate: candidate, opponent: baseline, seeds: seeds),
      candidate_calibration: calibration ? arena.compare(candidate: candidate, opponent: candidate, seeds: seeds) : nil,
      baseline_calibration: calibration ? arena.compare(candidate: baseline, opponent: baseline, seeds: seeds) : nil
    }
  end

  def evaluate(options)
    training = JSON.parse(File.read(options.fetch(:report), encoding: 'UTF-8'))
    selected = training.fetch('selected_profiles')
    profiles = options[:profiles] || selected.keys - SpadesLearning::PROFILE_KEYS
    validate_profiles!(profiles)
    game = GameRoomGames::Spades.new
    baseline_set = SpadesLearning::PolicySet.default
    seeds = Array.new(options.fetch(:seeds)) { |index| options.fetch(:seed) + index * 1_009 }
    records = profiles.map do |arrangement|
      profile, player_count, team_size = SpadesLearning::ARRANGEMENT_PROFILES.fetch(arrangement)
      scenarios = SpadesLearning::ScenarioMatrix.for_arrangement(profile, player_count: player_count,
        team_size: team_size, score_limits: options.fetch(:score_limits))
      state = {options: scenarios.first.options, players: GameRoomParticipants.bots_for(1, player_count)}
      candidate = SpadesLearning::Policy.complete(profile, selected.fetch(arrangement))
      baseline = baseline_set.for_state(state)
      arena = SpadesLearning::Arena.new(game: game, scenarios: scenarios, max_actions: options.fetch(:max_actions))
      comparisons = compare(arena, candidate, baseline, seeds, calibration: options.fetch(:calibration))
      evaluation = comparisons.fetch(:head_to_head)
      evaluation_hash(evaluation).merge(arrangement: arrangement,
        quality_advantage: evaluation.quality_advantage(quicksand: scenarios.all?(&:quicksand)),
        candidate_calibration: comparisons[:candidate_calibration] && evaluation_hash(comparisons[:candidate_calibration]),
        baseline_calibration: comparisons[:baseline_calibration] && evaluation_hash(comparisons[:baseline_calibration]))
    end
    {format: 'spades-evaluation-v1', generated_at: Time.now.utc.iso8601,
      source_report: options.fetch(:report), seed: options.fetch(:seed), seeds: options.fetch(:seeds),
      score_limits: options.fetch(:score_limits), comparison: 'candidate profiles versus current runtime profiles', arrangements: records}
  end

  def validate_profiles!(profiles)
    raise ArgumentError, 'Select at least one profile' if profiles.empty?
    unknown = profiles - SpadesLearning::ARRANGEMENT_PROFILES.keys
    raise ArgumentError, "Unknown arrangements: #{unknown.join(', ')}" unless unknown.empty?
  end

  def evaluation_hash(evaluation)
    {
      games: evaluation.games,
      wins: evaluation.wins,
      neutral_wins: evaluation.neutral_wins,
      average_margin: evaluation.average_margin,
      average_actions: evaluation.average_actions,
      average_rounds: evaluation.average_rounds,
      bid_accuracy_margin: evaluation.bid_accuracy_margin,
      candidate_bid_error: evaluation.candidate_bid_error,
      opponent_bid_error: evaluation.opponent_bid_error,
      candidate_bid_bias: evaluation.candidate_bid_bias,
      opponent_bid_bias: evaluation.opponent_bid_bias,
      candidate_contract_rate: evaluation.candidate_contract_rate,
      opponent_contract_rate: evaluation.opponent_contract_rate,
      candidate_average_overtricks: evaluation.candidate_average_overtricks,
      opponent_average_overtricks: evaluation.opponent_average_overtricks,
      candidate_average_shortfall: evaluation.candidate_average_shortfall,
      opponent_average_shortfall: evaluation.opponent_average_shortfall,
      quality_advantage_standard: evaluation.quality_advantage(quicksand: false),
      quality_advantage_quicksand: evaluation.quality_advantage(quicksand: true),
      average_table_bid_gap: evaluation.average_table_bid_gap,
      average_table_bid_deficit: evaluation.average_table_bid_deficit,
      incomplete_games: evaluation.incomplete_games
    }
  end

  def holdout_accepted?(head_to_head, candidate_calibration, baseline_calibration, quicksand:)
    return false if head_to_head.incomplete_games > 0 ||
      candidate_calibration.incomplete_games > 0 || baseline_calibration.incomplete_games > 0

    match_better = head_to_head.wins > head_to_head.neutral_wins &&
      head_to_head.average_margin >= -0.02 && head_to_head.bid_accuracy_margin >= -0.10
    match_not_worse = head_to_head.wins >= head_to_head.neutral_wins &&
      head_to_head.average_margin >= -0.01
    bid_improvement = baseline_calibration.candidate_bid_error - candidate_calibration.candidate_bid_error
    gap_improvement = baseline_calibration.average_table_bid_gap - candidate_calibration.average_table_bid_gap
    head_quality = head_to_head.quality_advantage(quicksand: quicksand)
    candidate_quality = candidate_calibration.policy_quality(:candidate, quicksand: quicksand)
    baseline_quality = baseline_calibration.policy_quality(:candidate, quicksand: quicksand)
    absolute_quality_improvement = candidate_quality - baseline_quality
    calibrated_better = bid_improvement > 0.05 || gap_improvement > 0.10 ||
      absolute_quality_improvement > 0.03
    quality_preserved = head_quality >= -0.03 && absolute_quality_improvement >= -0.02
    overtrick_tolerance = quicksand ? 0.20 : 0.50
    strong_match = head_to_head.wins >= head_to_head.neutral_wins + 2 &&
      head_to_head.average_margin >= 0.03 && head_quality >= -0.12 &&
      head_to_head.candidate_contract_rate >= head_to_head.opponent_contract_rate - 0.08 &&
      head_to_head.candidate_bid_error <= head_to_head.opponent_bid_error + 0.25 &&
      head_to_head.candidate_average_overtricks <=
        head_to_head.opponent_average_overtricks + overtrick_tolerance
    strong_match || (quality_preserved && (match_better || (match_not_worse && calibrated_better)))
  end

  def train(options)
    game = GameRoomGames::Spades.new
    policies = SpadesLearning::PolicySet.default
    selected_weights = policies.to_h
    records = []

    options[:profiles].each_with_index do |arrangement, arrangement_index|
      profile, player_count, team_size = SpadesLearning::ARRANGEMENT_PROFILES.fetch(arrangement)
      scenarios = SpadesLearning::ScenarioMatrix.for_arrangement(
        profile,
        player_count: player_count,
        team_size: team_size,
        score_limits: options[:score_limits]
      )
      state = { options: scenarios.first.options, players: GameRoomParticipants.bots_for(1, player_count) }
      baseline = policies.for_state(state)
      seed = options[:seed] + arrangement_index * 10_000_000
      warn "Training #{arrangement}..."
      trainer = SpadesLearning::CampaignTrainer.new(
        game: game,
        profile: profile,
        policy: baseline,
        seed: seed,
        scenarios: scenarios
      )
      campaign = trainer.train(
        max_series: options[:max_series],
        plateau_limit: options[:plateau_limit],
        generations_per_series: options[:generations],
        population: options[:population],
        scenarios_per_generation: [scenarios.length, 2].min,
        evaluation_seeds: options[:evaluation_seeds],
        validation_seeds: options[:validation_seeds],
        mutation_scale: options[:mutation_scale],
        training_max_actions: options[:training_max_actions],
        validation_max_actions: options[:validation_max_actions]
      ) do |entry|
        validation = entry[:validation]
        warn format(
          "  series %d: %s, %d/%d wins, margin %+.4f, bid %+.4f",
          entry[:series], entry[:accepted] ? "accepted" : "rejected",
          validation[:wins], validation[:neutral_wins], validation[:average_margin],
          validation[:bid_accuracy_margin]
        )
      end

      candidate = campaign.policy
      holdout_arena = SpadesLearning::Arena.new(
        game: game, scenarios: scenarios, max_actions: options[:validation_max_actions]
      )
      holdout_seeds = Array.new(options[:holdout_seeds]) do |index|
        seed + 900_000_000 + index * 7_919
      end
      comparisons = compare(holdout_arena, candidate, baseline, holdout_seeds)
      head_to_head, candidate_calibration, baseline_calibration = comparisons.values_at(:head_to_head, :candidate_calibration, :baseline_calibration)
      accepted = candidate.weights != baseline.weights &&
        holdout_accepted?(
          head_to_head, candidate_calibration, baseline_calibration,
          quicksand: scenarios.all? { |scenario| scenario.quicksand == true }
        )
      selected_weights[arrangement] = SpadesLearning::Policy.complete(
        profile, accepted ? candidate : baseline
      ).to_h
      warn format(
        "  holdout: %s, %d/%d wins, margin %+.4f, bid error %.3f -> %.3f, gap %.3f -> %.3f",
        accepted ? "accepted" : "kept baseline",
        head_to_head.wins, head_to_head.neutral_wins, head_to_head.average_margin,
        baseline_calibration.candidate_bid_error, candidate_calibration.candidate_bid_error,
        baseline_calibration.average_table_bid_gap, candidate_calibration.average_table_bid_gap
      )
      records << {
        arrangement: arrangement,
        profile: profile,
        player_count: player_count,
        team_size: team_size,
        accepted: accepted,
        campaign_series: campaign.series,
        campaign_accepted_series: campaign.accepted_series,
        head_to_head: evaluation_hash(head_to_head),
        candidate_calibration: evaluation_hash(candidate_calibration),
        baseline_calibration: evaluation_hash(baseline_calibration),
        campaign_history: campaign.history
      }
    end

    {
      format: 'spades-campaign-v1',
      generated_at: Time.now.utc.iso8601,
      settings: options.reject { |key, _value| key == :output },
      selected_profiles: selected_weights,
      arrangements: records
    }
  end
end
