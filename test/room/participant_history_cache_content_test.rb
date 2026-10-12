require_relative "../support/cat_head_tail"
require_relative "../../lib/game_content"
require_relative "../../content/languages"
require_relative "../../content/quiz_witcher_pl"
require_relative "../../games/quiz_party"

class QuizHistoryRepository
  def players_for(session); session.fetch('__players'); end
  def actor_of(event, _session = nil); event.fetch('actor'); end
  def event_id(event); event.fetch('id'); end
end

game = GameRoomGames::QuizParty.new
repository = QuizHistoryRepository.new
session = { '__id' => 77, '__players' => %w[Alice Bob], 'options' => JSON.generate(game.default_options.merge('answer_time' => 5)) }
events = []
contexts = %w[Alice Bob].to_h do |actor|
  [actor, GameRoomGames::ActionContext.new(session_id: 77, now: 1000,
    random_source: GameRoomRandom::SeededSource.new(49),
    hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new))]
end
replay = -> { game.replay(session, events, repository) }
append = lambda do |actor, outcome, time|
  status, plan = outcome
  assert(status == :ok && plan, "Plan rejected: #{status}")
  plan.events.each do |event|
    events << { 'id' => events.length + 1, 'actor' => actor, 'action' => event.action,
      'value' => event.value, 'created_at' => time }
  end
end
automatic = lambda do |action, actor, now|
  contexts.fetch(actor).now = now
  append.call(actor, game.send(:automatic_plan, action, replay.call.state, actor, contexts.fetch(actor)), now)
end
automatic.call('draw_categories', 'Alice', 1000)
append.call('Alice', game.send(:submit_category, { 'answer' => replay.call.state[:choices].first }, replay.call.state, 'Alice'), 1000)
first_commit = nil
3.times do |index|
  start = 1000 + index * 20
  automatic.call('start_question', 'Alice', start)
  %w[Alice Bob].each do |actor|
    state = replay.call.state
    contexts.fetch(actor).now = start + 4
    selection = { 'question_id' => game.send(:question_surface_id, state), 'answer' => game.send(:correct_option_index, state).to_s }
    append.call(actor, game.send(:submit_answer, selection, state, actor, contexts.fetch(actor)), start + 7)
    first_commit ||= events.last.fetch('id')
  end
  automatic.call('close_answers', 'Alice', start + 8)
  %w[Alice Bob].each { |actor| automatic.call('reveal', actor, start + 8) }
  automatic.call('finish_question', 'Alice', start + 9)
end
assert(replay.call.state[:completed_rounds] == 1, 'fixture must finish a genuine Quiz round')
assert(replay.call.accepted_events.length == events.length, 'fixture history contains invalid moves')
session.merge!('__players' => %w[Carol Bob], '__initial_players' => %w[Alice Bob],
  '__seat_changes' => [{ 'id' => events.last.fetch('id') + 1, 'players' => %w[Carol Bob] }])
original = Marshal.load(Marshal.dump(events))
first_view = game.replay(session, events, repository)
expected_history = Marshal.load(Marshal.dump(first_view.history))
historical_entry = first_view.history.find { |entry| entry.event_id.to_i < session['__seat_changes'][0]['id'] }
assert(historical_entry && historical_entry.text.is_a?(String), 'fixture needs an earlier participant history entry')
historical_entry.text.replace('Caller changed the returned historical message')
assert(game.replay(session, events, repository).history == expected_history,
  'caller mutation leaked into the cached historical participant segment')
assert(events == original, 'presentation mutation changed the source history')
mutations = [
  -> { events.find { |e| e['id'] == first_commit }['created_at'] += 1 },
  -> { events.replace(Marshal.load(Marshal.dump(original))); events[2]['actor'] = 'Unknown' },
  -> { events.replace(Marshal.load(Marshal.dump(original))); events[2]['value'] = '{}' },
  -> { events.replace(Marshal.load(Marshal.dump(original))); session['options'] = JSON.generate(game.default_options.merge('answer_time' => 10)) },
  -> { session['__seat_changes'][0]['players'][0] = 'Dana'; session['__players'][0] = 'Dana' }
]
mutations.each_with_index do |change, index|
  change.call
  cached = game.replay(session, events, repository)
  fresh = GameRoomGames::QuizParty.new.replay(session, events, repository)
  assert(cached.to_h == fresh.to_h, "cached Quiz differs from full replay after mutation #{index}")
  assert(game.instance_variable_get(:@participant_history_cache)[:segments].size == 1, 'old prefix variants accumulate')
end
puts 'PASS participant history cache: real Quiz, caller-owned historical messages, earlier timestamp/author/value and mutable settings/roster'
