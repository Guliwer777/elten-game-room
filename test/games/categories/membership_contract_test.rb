require_relative '../../support/categories'
require_relative '../../support/sequence_random'

# Independent model-level coverage. The companion runner test verifies that
# only authenticated native membership changes can produce this event.
class CategoriesMembershipFixture
  attr_reader :game, :players, :repository, :session, :context, :events

  def initialize(players: %w[Alice Bob Carol Dave], judge_mode: 'rotating')
    @game = GameRoomGames::Categories.new
    @players = players
    @repository = CategoriesRepository.new(players)
    options = game.normalize_options(game.default_options.merge(
      'category_set' => 'custom', 'custom_categories' => %w[country city],
      'round_category_count' => 2, 'round_time' => 90, 'target_score' => 100,
      'judge_mode' => judge_mode))
    @session = {'options' => JSON.generate(options)}
    @context = GameRoomGames::ActionContext.new(session_id: 901, table_id: 902,
      now: 100, table_owner: 'Alice',
      hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new),
      random_source: GameRoomRandom::SequenceSource.new([1, 1, 1, 1]))
    @events = []
    commit('Alice')
  end

  def replay; game.replay(session, events, repository); end

  def commit(actor, selection = nil)
    current = replay
    selection ||= game.automatic_action(current, actor, context: context)
    assert(selection, "Missing fixture action for #{actor} in #{current.state[:phase]}")
    status, plan = game.action_for(selection, current, actor, context: context)
    assert(status == :ok, "Fixture action failed: #{actor}, #{status}, #{selection.inspect}")
    append_plan(events, plan, actor, now: context.now)
    replay
  end

  def answer(actor)
    country, city = {'Bob' => %w[Austria Athens], 'Carol' => %w[Argentina Athens],
      'Dave' => %w[Australia Ankara]}.fetch(actor)
    commit(actor, surface_action('answer_sheet', 'submit',
      'answers' => {'country' => country, 'city' => city}))
  end

  def review
    replay.state[:active_players].each { |actor| answer(actor) }
    commit('Alice')
    replay.state[:active_players].each { |actor| commit(actor) }
    commit('Alice')
    assert(replay.state[:phase] == :review, 'Fixture did not reach review')
    self
  end

  def grade
    items = game.send(:review_items, replay.state)
    decisions = items.to_h { |item| [item[:id], item[:players].size > 1 ? 'duplicate' : 'unique'] }
    commit(replay.state[:judge], surface_action('review', 'finish', 'decisions' => decisions))
    self
  end

  def remove(names, owner: 'Alice', judge_left: false)
    context.table_owner = owner
    current = replay
    selection = surface_action('membership', 'remove', 'players' => names,
      'judge' => owner, 'judge_left' => judge_left, 'attempt' => current.state[:attempt])
    status, plan = game.action_for(selection, current, players.first, context: context)
    assert(status == :ok, "Membership plan rejected: #{status}")
    first = events.length
    append_plan(events, plan, players.first, now: context.now)
    events.drop(first).each do |event|
      event.merge!('__controller' => true, '__authority_user' => owner, '__insertion_user' => owner)
    end
    replay
  end
end

f = CategoriesMembershipFixture.new
f.answer('Bob')
before = f.replay
after = f.remove(['Bob'])
assert(after.state[:active_players] == %w[Carol Dave], 'Departed answerer still participates')
assert(after.state[:commitments].empty?, 'Departed player kept an unrevealed commitment')
assert(after.history.first(before.history.length) == before.history, 'Departure rewrote prior history')
assert(f.game.eliminated_from_game?(after, 'bOb'), 'Returning player is not identified as eliminated')
assert(f.game.membership_action(after, members: %w[Alice Bob Carol Dave], table_owner: 'Alice').nil?,
  'Rejoining membership resurrected an eliminated player')
status, = f.game.action_for(surface_action('answer_sheet', 'submit', 'answers' => {'country' => 'Austria'}),
  after, 'Bob', context: f.context)
assert(status != :ok, 'An eliminated player can answer again after rejoining')

# A partly received private envelope must not stall all remaining players.
f = CategoriesMembershipFixture.new
%w[Bob Carol Dave].each { |actor| f.answer(actor) }
f.commit('Alice')
selection = f.game.automatic_action(f.replay, 'Bob', context: f.context)
status, plan = f.game.action_for(selection, f.replay, 'Bob', context: f.context)
assert(status == :ok, 'Could not prepare a real reveal envelope')
append_plan(f.events, GameRoomGames::ActionPlan.new(events: [plan.events.first]), 'Bob')
assert(!f.replay.state[:reveal_parts]['Bob'].empty?, 'Partial envelope setup failed')
f.commit('Carol')
f.commit('Dave')
f.remove(['Bob'])
%i[commitments reveals reveal_parts].each do |key|
  assert(!f.replay.state[key].key?('Bob'), "Departed player retained #{key}")
end
f.commit('Alice')
assert(f.replay.state[:phase] == :review, 'A discarded private envelope still blocks review')

# Existing positional IDs must survive removal. A changed duplicate group
# requires a new decision; unrelated decisions must not jump to another player.
f = CategoriesMembershipFixture.new.review.grade
graded = f.replay
after = f.remove(['Carol'])
assert(after.state[:decisions] == {'1:0:0' => 'unique', '1:2:0' => 'unique', '1:2:1' => 'unique'},
  'Removal kept a stale duplicate grade or shifted an unrelated answer ID')
assert(!after.state[:review_finished], 'Changed duplicate group remained marked fully reviewed')
assert(f.game.send(:review_items, after.state).map { |item| item[:id] } == %w[1:0:0 1:0:1 1:2:0 1:2:1],
  'Stable review IDs moved after removal of the middle player')
assert(after.state[:scores].values.all?(&:zero?), 'Departure awarded unfinished points')

# A scored prefix is rolled back before the surviving answers are recalculated.
f = CategoriesMembershipFixture.new.review.grade
selection = f.game.automatic_action(f.replay, 'Alice', context: f.context)
status, plan = f.game.action_for(selection, f.replay, 'Alice', context: f.context)
assert(status == :ok, 'Could not prepare score batch')
append_plan(f.events, GameRoomGames::ActionPlan.new(events: [plan.events.first]), 'Alice')
assert(f.replay.state[:scores]['Bob'] == 3, 'Partial score setup failed')
f.remove(['Carol'])
assert(f.replay.state[:scores].values.all?(&:zero?) && f.replay.state[:round_scores].empty?,
  'Partly applied score batch was not rolled back')
f.grade
finished = f.commit('Alice')
assert(finished.state[:scores] == {'Alice' => 0, 'Bob' => 4, 'Carol' => 0, 'Dave' => 4},
  'Surviving answers scored twice or retained the old duplicate count')
assert(finished.state[:completed_rounds] == 1, 'Scored round did not finish exactly once')
scored_history = finished.history.dup
f.remove(['Dave'])
assert(f.replay.state[:scores] == finished.state[:scores], 'Departure changed completed round points')
assert(f.replay.history.first(scored_history.length) == scored_history, 'Departure rewrote completed history')

# Removing the judge cancels only the unfinished round. The next attempt has
# another judge and letter and receives the entire configured answer duration.
f = CategoriesMembershipFixture.new
before = f.replay
cancelled = f.remove(['Alice'], owner: 'Bob')
assert(cancelled.state[:phase] == :round_complete && cancelled.state[:completed_rounds] == 0,
  'Departed rotating judge did not cancel the unfinished round')
assert(cancelled.state[:commitments].empty? && cancelled.state[:decisions].empty?, 'Cancelled round retained work')
f.context.now = cancelled.state[:resume_at]
restarted = f.commit('Alice')
assert(restarted.state[:judge] == 'Bob' && restarted.state[:active_players] == %w[Carol Dave],
  'Next rotating judge/contestants did not skip the departed seat')
assert(restarted.state[:letter] != before.state[:letter] && restarted.state[:attempt] == before.state[:attempt] + 1,
  'Cancelled attempt reused its letter or envelope identity')
assert(restarted.state[:deadline] == f.context.now + 90, 'New round inherited the expired deadline')

f = CategoriesMembershipFixture.new(judge_mode: 'master')
f.remove(['Alice'], owner: 'Bob', judge_left: true)
f.context.now = f.replay.state[:resume_at]
next_round = f.commit('Alice')
assert(next_round.state[:judge] == 'Bob' && next_round.state[:active_players] == %w[Carol Dave],
  'New permanent judge was allowed to answer their own round')

# A host transfer alone is not departure and must not cancel an unrelated judge.
assert(f.game.membership_action(next_round, members: %w[Bob Carol Dave], table_owner: 'Dave').nil?,
  'Host transfer alone removed an existing judge')

f = CategoriesMembershipFixture.new(players: %w[Alice Bob])
interrupted = f.remove(['Bob'])
assert(interrupted.state[:phase] == :interrupted && !interrupted.finished? && !interrupted.winner && !interrupted.draw,
  'Insufficient participants were manufactured into a victory or draw')
assert(f.game.interruption_reason(interrupted) && interrupted.history.any? { |row| row.kind == :final_scores },
  'Interrupted game has no explicit reason or final score history')

# Replay accepts only the controller-authenticated event, never a plain client
# action or an event whose insertion account disagrees with the authority.
valid = f.events.last
%w[__controller __authority_user __insertion_user].each do |field|
  invalid = valid.reject { |key, _| key == field }
  replay = f.game.replay(f.session, f.events[0...-1] + [invalid], f.repository)
  assert(replay.state[:departed_players].empty?, "Unauthenticated removal accepted without #{field}")
end
invalid = valid.merge('__insertion_user' => 'Bob')
assert(f.game.replay(f.session, f.events[0...-1] + [invalid], f.repository).state[:departed_players].empty?,
  'A different insertion account removed a participant')

puts 'PASS Categories membership model: private cleanup, stable review IDs, score rollback, immutable completed history, rotating/permanent judge, interrupted outcome and authenticated removal'
