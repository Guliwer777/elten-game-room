require_relative '../support/assertions'
require_relative '../../lib/tournaments/knockout_schedule'
require_relative '../../lib/tournaments/group_stage'
include GameRoomTest::Assertions
T = GameRoomTournaments

# Pure sporting projections. These are neither accepted match receipts nor a
# substitute for the source/digest checks in an execution-plan contract.
base = T::KnockoutRound.build(seeds: %w[a b c d], players_per_match: 2, round_number: 1)
plans = {
  'ordinary' => base,
  'replay' => T::KnockoutReplay.build(base: base, resolved: [], attempt: 1),
  'series' => T::KnockoutWinSeries.build(base: base, history: [], target: 2, attempt: 1)
}
configuration = {participants: %w[a b c d], group_count: 2, places_per_group: 1,
  players_per_match: 2, pairing: 'all_combinations', rematch: false}
groups = T::GroupPlan.build(**configuration).fetch('groups')
results = groups.map do |group|
  group.fetch('matches').map { |match| match.slice('id', 'participants').merge('winners' => []) }
end
stage = T::GroupStage.calculate(configuration: configuration, results: results.flatten(1))
snapshot = T::GroupTiebreak.snapshot(summary: {'groups' => stage.fetch('groups'), 'group_results' => results},
  candidate: {'group_advancement' => T::GroupAdvancement::AUTOMATIC})
plans['qualification'] = T::GroupTiebreak.build(snapshot: snapshot, attempt: 1)

structures = lambda do |value, path = [], &walk|
  next [] unless value.is_a?(Hash) || value.is_a?(Array)
  children = value.is_a?(Hash) ? value.to_a : value.empty? ? [] : [[0, value.first]]
  [path] + children.flat_map { |key, child| walk.call(child, path + [key], &walk) }
end
checks = 0
plans.each do |name, plan|
  metadata = plan.slice('round', 'seeds', 'players_per_match', 'generation', 'replay', 'series', 'qualification')
    .merge('phase_digest' => 'a' * 64, 'parent_plan_digest' => 'b' * 64)
  valid = T::KnockoutSchedule.matches(metadata: metadata, generation: 'roster')
  frozen_bytes = JSON.generate(metadata)
  structures.call(metadata, [], &structures).each do |path|
    original = path.inject(metadata) { |node, key| node.fetch(key) }
    [nil, false, true, 7, 1.5, 'bad', [], {}].each do |replacement|
      next if original == replacement
      changed = JSON.parse(frozen_bytes)
      if path.empty?
        changed = replacement
      else
        parent = path[0...-1].inject(changed) { |node, key| node.fetch(key) }
        parent[path.last] = replacement
      end
      unchanged = JSON.generate(changed)
      assert_raises(T::Publication::Invalid) do
        T::KnockoutSchedule.matches(metadata: changed, generation: 'roster')
      end
      assert_equal(unchanged, JSON.generate(changed), 'A structural refusal must not normalize its input')
      checks += 1
    end
  end
  assert_equal(valid, T::KnockoutSchedule.matches(metadata: metadata, generation: 'roster'))
  assert_equal(frozen_bytes, JSON.generate(metadata))
end
puts "PASS knockout metadata: #{checks} typed shape refusals; ordinary, replay, series and qualification projections unchanged"
