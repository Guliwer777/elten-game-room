require_relative '../../support/categories'
require_relative '../../support/sequence_random'

# Independent reducer review: construct verified answer envelopes and retain
# the older round/review dialect, not the implementation author's fixture.
class CategoriesHistoricalReviewFixture
  attr_reader :game, :session, :repository, :context, :events

  def initialize
    @game = GameRoomGames::Categories.new
    @repository = CategoriesRepository.new(%w[Alice Bob Carol Dave])
    options = game.normalize_options(game.default_options.merge(
      'category_set'=>'custom', 'custom_categories'=>%w[country city],
      'round_category_count'=>2, 'round_time'=>0, 'target_score'=>1000))
    @session = {'options'=>JSON.generate(options)}
    @context = GameRoomGames::ActionContext.new(session_id:771, table_id:772, now:100,
      table_owner:'Alice', random_source:GameRoomRandom::SequenceSource.new(Array.new(20, 1)),
      hidden_submissions:HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new))
    @events = []
  end

  def replay(records = events)
    game.replay(session, records, repository)
  end

  def raw(action, value, actor, records = events)
    records << {'id'=>records.length + 1, 'actor'=>actor, 'action'=>action,
      'value'=>value.to_s, 'created_at'=>context.now}
  end

  def commit(actor, selection = nil)
    before = replay
    selection ||= game.automatic_action(before, actor, context:context)
    assert(selection, "Missing fixture selection in #{before.state[:phase]}")
    status, plan = game.action_for(selection, before, actor, context:context)
    assert(status == :ok && plan, "Fixture selection rejected: #{status}")
    append_plan(events, plan, actor, now:context.now)
    after = replay
    assert(after.accepted_events.size == events.size, 'Fixture created a rejected event')
    after
  end

  def open_review
    before = replay
    context.now = [context.now, before.state[:resume_at].to_i].max
    if events.empty?
      # Dot-separated category IDs are a legitimate older wire format.
      raw('category_round', '1,1,0,A,0,country.city', 'Alice')
    else
      commit('Alice')
    end
    assert(replay.state[:phase] == :answering, 'Round did not start')
    replay.state[:active_players].each_with_index do |actor, index|
      country = ['Austria', '  AUSTRIA  ', 'Argentina'].fetch(index)
      city = ['Amsterdam', 'Athens', ''].fetch(index)
      commit(actor, surface_action('answer_sheet', 'submit', 'answers'=>{'country'=>country, 'city'=>city}))
    end
    commit('Alice')
    replay.state[:active_players].each { |actor| commit(actor) }
    commit('Alice')
    assert(replay.state[:phase] == :review, 'Review did not start')
    self
  end

  def items
    game.send(:review_items, replay.state)
  end

  def legacy_grade
    items.each { |item| raw('review_correct', item[:id], replay.state[:judge]) }
    raw('review_finished', '', replay.state[:judge])
    assert(replay.state[:review_finished], 'Older correct/finished review dialect stopped working')
    assert(replay.accepted_events.size == events.size, 'Historical review event rejected')
    self
  end

  def finish_round
    commit('Alice')
    self
  end
end

failures = []
checks = 0
check = lambda do |condition, message|
  checks += 1
  failures << message unless condition
end

f = CategoriesHistoricalReviewFixture.new.open_review
original = f.replay
single = f.items.find { |item| item[:players].size == 1 }
duplicate = f.items.find { |item| item[:players].size == 2 }
assert(single && duplicate && f.items.size == 4, 'Independent fixture needs unique, duplicate and blank answers')

# Per-answer and aggregate paths must agree, including grouping normalized
# copies without changing the stored answers or the historical item order.
[[single, 'duplicate'], [duplicate, 'unique'], [duplicate, 'partial']].each do |item, decision|
  selection = surface_action('review', 'change', 'item_id'=>item[:id], 'decision'=>decision)
  status, plan = f.game.action_for(selection, original, 'Alice', context:f.context)
  check.call(status == :invalid && plan.nil?, "Direct input accepted forbidden #{decision}")
  records = f.events.map(&:dup)
  f.raw("review_#{decision}", item[:id], 'Alice', records)
  after = f.replay(records)
  check.call(after.state[:decisions] == original.state[:decisions] &&
    after.accepted_events == original.accepted_events, "Replay accepted forbidden #{decision}")
end

f.items.each do |item|
  allowed = item[:players].size == 1 ? %w[unique partial incorrect] : %w[duplicate incorrect]
  allowed.each do |decision|
    records = f.events.map(&:dup)
    f.raw("review_#{decision}", item[:id], 'aLiCe', records)
    after = f.replay(records)
    check.call(after.state[:decisions][item[:id]] == decision, "Legal #{decision} was rejected")
    f.raw('review_clear', item[:id], 'Alice', records)
    check.call(f.replay(records).state[:decisions].empty?, "Cannot clear legal #{decision}")
  end
end

records = f.events.map(&:dup)
f.raw('review_correct', single[:id], 'Bob', records)
f.raw('review_correct', '1:999:0', 'Alice', records)
check.call(f.replay(records).accepted_events == original.accepted_events, 'Wrong judge or unknown item was accepted')

aggregate = f.items.map { |item| item[:players].size > 1 ? 'd' : 'u' }.join
records = f.events.map(&:dup)
f.raw('review_commit', aggregate, 'Alice', records)
modern = f.replay(records)
f.legacy_grade
historical = f.replay
check.call(historical.state[:decisions] == modern.state[:decisions], 'Older review_correct changed its meaning')
check.call(historical.state[:review_finished] && modern.state[:review_finished], 'Review completion dialects disagree')
f.raw('review_incorrect', single[:id], 'Alice', records)
check.call(f.replay(records).state[:decisions] == modern.state[:decisions], 'Assessment changed after completion')

legacy_scored = f.commit('Alice')
modern_status, modern_plan = f.game.action_for(
  f.game.automatic_action(modern, 'Alice', context:f.context), modern, 'Alice', context:f.context)
assert(modern_status == :ok, 'Modern scoring selection was unavailable')
records.pop
append_plan(records, modern_plan, 'Alice', now:f.context.now)
check.call(f.replay(records).state[:scores] == legacy_scored.state[:scores], 'Historical/aggregate scores differ')

# The current sender uses one atomic scoring batch. This deliberately explores
# valid historical scoring prefixes as reducer hardening, not as a claim that
# a modern network write splits that batch.
f = CategoriesHistoricalReviewFixture.new
2.times { f.open_review.legacy_grade.finish_round }
f.open_review.legacy_grade
before = f.replay
scoring_status, scoring_plan = f.game.action_for(
  f.game.automatic_action(before, 'Alice', context:f.context), before, 'Alice', context:f.context)
assert(scoring_status == :ok && scoring_plan.events.last.action == 'round_finished', 'No complete scoring batch')
scores = scoring_plan.events[0...-1]
assert(scores.size == 3, 'Expected three contestant scores')

[scores, scores.reverse].each_with_index do |order, order_index|
  (0..scores.size).each do |length|
    records = f.events.map(&:dup)
    append_plan(records, GameRoomGames::ActionPlan.new(events:order.take(length)), 'Alice', now:f.context.now)
    prefix = f.replay(records)
    selection = surface_action('command', 'cancel_round')
    status, plan = f.game.action_for(selection, prefix, 'Alice', context:f.context)
    assert(status == :ok, 'Owner cancellation must remain available before round_finished')
    append_plan(records, plan, 'Alice', now:f.context.now)
    cancelled = f.replay(records)
    label = "order #{order_index}, #{length} scores"
    check.call(cancelled.state[:scores] == before.state[:scores], "Cancelled prefix retained score: #{label}")
    check.call(cancelled.state[:round_scores].empty?, "Cancelled prefix retained round cache: #{label}")
    check.call(cancelled.state.values_at(:completed_rounds, :tournament_checkpoint, :judge_queue, :final_end_round) ==
      before.state.values_at(:completed_rounds, :tournament_checkpoint, :judge_queue, :final_end_round),
      "Cancellation changed a completed checkpoint/judge cycle: #{label}")
    check.call(cancelled.history.take(prefix.history.size) == prefix.history, "History was rewritten: #{label}")
    check.call(!cancelled.finished? && cancelled.state[:phase] == :round_complete, "Cancellation awarded a result: #{label}")
    f.raw('round_cancelled', before.state[:round], 'Alice', records)
    repeated = f.replay(records)
    check.call(repeated.state[:scores] == cancelled.state[:scores] &&
      repeated.accepted_events == cancelled.accepted_events, "Duplicate cancellation applied twice: #{label}")
    start = f.game.automatic_action(repeated, 'Alice', context:f.context)
    next_status, next_plan = f.game.action_for(start, repeated, 'Alice', context:f.context)
    assert(next_status == :ok, 'Cancelled round cannot restart')
    append_plan(records, next_plan, 'Alice', now:f.context.now)
    restarted = f.replay(records)
    check.call(restarted.state[:scores] == before.state[:scores] && restarted.state[:judge] == before.state[:judge] &&
      restarted.state[:attempt] == before.state[:attempt] + 1 && restarted.state[:decisions].empty?,
      "Restart leaked scores, judge advancement or assessments: #{label}")
  end
end

complete_records = f.events.map(&:dup)
append_plan(complete_records, scoring_plan, 'Alice', now:f.context.now)
complete = f.replay(complete_records)
f.raw('round_cancelled', complete.state[:round], 'Alice', complete_records)
check.call(f.replay(complete_records).state[:scores] == complete.state[:scores] &&
  f.replay(complete_records).accepted_events == complete.accepted_events, 'Cancellation rolled back a completed round')

raise failures.join("\n") unless failures.empty?
puts "PASS independent Categories review/cancellation: #{checks} checks; legacy review dialect, normalized groups, negative input/replay, ordered/reversed score prefixes, duplicate cancellation and restart after two completed rounds"
