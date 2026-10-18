require_relative '../../support/categories'
require_relative '../../support/sequence_random'

# Build the review only from accepted actions and verified private envelopes.
class CategoriesReviewBoundaryFixture
  attr_reader :game, :repository, :session, :context, :events

  def initialize
    @game = GameRoomGames::Categories.new
    @repository = CategoriesRepository.new(%w[Alice Bob Carol])
    options = game.normalize_options(game.default_options.merge(
      'category_set' => 'custom', 'custom_categories' => %w[country city],
      'round_category_count' => 2, 'round_time' => 0, 'target_score' => 100))
    @session = {'options' => JSON.generate(options)}
    @context = GameRoomGames::ActionContext.new(session_id: 913, table_id: 914,
      now: 100, table_owner: 'Alice',
      hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new),
      random_source: GameRoomRandom::SequenceSource.new([1, 1, 1]))
    @events = []
  end

  def replay(records = events)
    game.replay(session, records, repository)
  end

  def commit(actor, selection = nil)
    current = replay
    selection ||= game.automatic_action(current, actor, context: context)
    assert(selection, "No action in #{current.state[:phase]}")
    status, plan = game.action_for(selection, current, actor, context: context)
    assert(status == :ok, "Fixture action rejected: #{status}")
    append_plan(events, plan, actor, now: context.now)
    replay
  end

  def review
    context.now = [context.now, replay.state[:resume_at]].max
    commit('Alice')
    actors = replay.state[:active_players].dup
    actors.each_with_index do |actor, i|
      commit(actor, surface_action('answer_sheet', 'submit',
        'answers' => {'country' => i.zero? ? 'Austria' : 'Argentina', 'city' => 'Athens'}))
    end
    commit('Alice')
    actors.each { |actor| commit(actor) }
    commit('Alice')
    assert(replay.state[:phase] == :review, 'Fixture did not reach review')
    self
  end

  def grade
    items = game.send(:review_items, replay.state)
    decisions = items.to_h { |item| [item[:id], item[:players].length > 1 ? 'duplicate' : 'unique'] }
    commit(replay.state[:judge], surface_action('review', 'finish', 'decisions' => decisions))
    self
  end
end

failures = []
check = lambda { |condition, message| failures << message unless condition }
f = CategoriesReviewBoundaryFixture.new.review
items = f.game.send(:review_items, f.replay.state)
duplicate = items.find { |item| item[:players].length == 2 }
single = items.find { |item| item[:players].length == 1 }
[[duplicate, 'unique'], [duplicate, 'partial'], [single, 'duplicate']].each do |item, decision|
  selection = surface_action('review', 'change', 'item_id' => item[:id], 'decision' => decision)
  status, plan = f.game.action_for(selection, f.replay, 'Alice', context: f.context)
  check.call(status != :ok && plan.nil?, "Action accepted #{decision} for #{item[:players].size} answerers")
  event = {'id' => f.events.length + 1, 'actor' => 'Alice', 'action' => "review_#{decision}",
    'value' => item[:id], 'created_at' => f.context.now}
  actual = f.replay(f.events + [event])
  check.call(actual.accepted_events.size == f.replay.accepted_events.size &&
    !actual.state[:decisions].key?(item[:id]), "Replay accepted #{decision} for #{item[:players].size} answerers")
end

# Cancellation must roll back any received scoring prefix, not completed rounds.
[0, 1].each do |completed_rounds|
  f = CategoriesReviewBoundaryFixture.new
  completed_rounds.times { f.review.grade.commit('Alice') }
  f.review.grade
  before = f.replay
  selection = f.game.automatic_action(before, 'Alice', context: f.context)
  status, plan = f.game.action_for(selection, before, 'Alice', context: f.context)
  assert(status == :ok && plan.events.last.action == 'round_finished', 'Missing real scoring batch')
  (1...plan.events.length).each do |prefix_size|
    records = f.events.map(&:dup)
    append_plan(records, GameRoomGames::ActionPlan.new(events: plan.events.take(prefix_size)), 'Alice', now: f.context.now)
    partial = f.replay(records)
    assert(partial.state[:scores] != before.state[:scores], 'Scoring prefix fixture added no points')
    cancel = surface_action('command', 'cancel_round')
    cancel_status, cancel_plan = f.game.action_for(cancel, partial, 'Alice', context: f.context)
    assert(cancel_status == :ok, 'Current cancel command unavailable')
    append_plan(records, cancel_plan, 'Alice', now: f.context.now)
    cancelled = f.replay(records)
    check.call(cancelled.state[:scores] == before.state[:scores] && cancelled.state[:round_scores].empty?,
      "Cancelled #{prefix_size}-score prefix retained points after #{completed_rounds} completed rounds")
    check.call(cancelled.state[:completed_rounds] == completed_rounds &&
      cancelled.state[:tournament_checkpoint] == before.state[:tournament_checkpoint], 'Cancellation rewrote the completed checkpoint')
    check.call(cancelled.state[:phase] == :round_complete && !cancelled.finished?, 'Cancellation fabricated a final result')
    check.call(cancelled.history.take(partial.history.length) == partial.history, 'Cancellation rewrote immutable history')
    cancelled_twice = f.replay(records + [records.last.merge('id' => records.last['id'] + 1)])
    check.call(cancelled_twice.state[:scores] == cancelled.state[:scores], 'Duplicate cancellation subtracted scores twice')
  end
end

raise failures.join("\n") unless failures.empty?
puts 'PASS Categories review boundaries: legal decisions below UI; partial score cancellation preserves completed scores/checkpoint/history and rejects duplicate rollback'
