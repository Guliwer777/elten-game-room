require_relative '../support/session_runner'
require_relative '../support/sequence_random'
require_relative '../../lib/game_lifecycle'

class NativeCategoriesMembershipFixture
  attr_reader :h, :game, :contexts, :runners

  def initialize(users: %w[Alice Bob Carol Dave], judge_mode: 'rotating', tournament: nil)
    @game = GameRoomGames::Categories.new
    options = game.normalize_options(game.default_options.merge('round_time' => 0,
      'category_set' => 'custom', 'custom_categories' => %w[country city],
      'round_category_count' => 2, 'target_score' => 100, 'judge_mode' => judge_mode))
    @h = NativeRoomHarness.new(game: game, users: users, options: options, tournament: tournament)
    h.start
    @contexts = users.to_h do |user|
      [user, GameRoomGames::ActionContext.new(session_id: h.session['__id'], table_id: h.table['__id'],
        now: Time.now.to_i, table_owner: 'Alice', random_source: GameRoomRandom::LocalSecureSource.new,
        hidden_submissions: HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new))]
    end
    @runners = {}
    h.submit('Alice', context: contexts.fetch('Alice'))
  end

  def replay(user = 'Alice'); h.replay(user); end

  def answer(user)
    h.submit(user, {'kind' => 'answer_sheet', 'action' => 'submit',
      'answers' => {'country' => "#{user}-country", 'city' => "#{user}-city"}}, context: contexts.fetch(user))
  end

  def review
    replay.state[:active_players].each { |user| answer(user) }
    h.submit('Alice', context: contexts.fetch('Alice'))
    replay.state[:active_players].each { |user| h.submit(user, context: contexts.fetch(user)) }
    h.submit('Alice', context: contexts.fetch('Alice'))
    assert(replay.state[:phase] == :review, 'Native fixture did not reach review')
    self
  end

  def score
    decisions = game.send(:review_items, replay.state).to_h { |item| [item[:id], 'unique'] }
    h.submit(replay.state[:judge], {'kind' => 'review', 'action' => 'finish', 'decisions' => decisions},
      context: contexts.fetch(replay.state[:judge]))
    h.submit('Alice', context: contexts.fetch('Alice'))
    self
  end

  def leave(user)
    h.as(user) do
      program = ProgramDouble.new(h.broker.endpoint(user))
      LobbyRepository.new(program, transport: h.transports.fetch(user), server_tables: Object.new).leave_table(h.table, user)
    end
  end

  def runner(user, covered: false)
    runners[user] ||= runner_for(h, user, covered: -> { covered })
  end

  def step(user, count: 1, covered: false)
    instance = runner(user, covered: covered)
    h.as(user) { count.times { instance.step } }
    error = instance.take_error
    raise error if error
    instance
  end

  def departures(user)
    replay(user).accepted_events.select { |event| event['action'] == 'participants_departed' }
  end

  def close; runners.each_value(&:close); end
end

# Nothing about a covered window or an otherwise quiet connection is a leave.
f = NativeCategoriesMembershipFixture.new
begin
  before = f.replay.accepted_events.length
  f.step('Alice', count: 8, covered: true)
  assert(f.replay.accepted_events.length == before && f.departures('Alice').empty?,
    'Covered, idle native membership removed an existing participant')
  f.answer('Bob')
  f.leave('Bob')
  f.step('Alice', count: 3)
  removed = f.replay
  assert(removed.state[:departed_players] == ['Bob'] && !removed.state[:commitments].key?('Bob'),
    'Native leave did not discard the departed private commitment')
  assert(removed.state[:phase] == :answering && removed.state[:active_players] == %w[Carol Dave],
    'An answerer leave cancelled or blocked the surviving round')
  assert(f.departures('Alice').length == 1, 'One native leave produced several removal events')
  row = f.departures('Alice').first
  assert(row['__controller'] == true && row['__authority_user'] == 'Alice' && row['__insertion_user'] == 'Alice',
    'Removal was not authenticated by the existing native controller ledger')
  assert(f.h.transports['Alice'].room_snapshot(f.h.table)[:bots].empty?, 'Removal invented an unsupported bot')
  assert(f.h.join('Bob'), 'Native return failed')
  f.step('Alice', count: 3)
  assert(f.replay('Bob').state[:departed_players] == ['Bob'], 'Native return resurrected the old game seat')
  assert(f.departures('Alice').length == 1, 'Native return repeated the removal')
  status, = f.game.action_for({'kind' => 'answer_sheet', 'action' => 'submit', 'answers' => {'country' => 'Austria'}},
    f.replay('Bob'), 'Bob', context: f.contexts['Bob'])
  assert(status != :ok, 'Returned account can submit to an eliminated seat')
  f.h.assert_converged('ordinary departure and return')
ensure
  f.close
end

# The judge leaving cancels the attempt. The real successor writes as the old
# owner seat through the existing controller ledger; no fake winner is inserted.
%w[rotating master].each do |judge_mode|
  f = NativeCategoriesMembershipFixture.new(judge_mode: judge_mode)
  begin
    f.answer('Carol')
    before = f.replay
    f.leave('Alice')
    successor = f.step('Bob', count: 3)
    cancelled = f.replay('Bob')
    assert(cancelled.state[:phase] == :round_complete && cancelled.state[:completed_rounds] == 0,
      "#{judge_mode}: native judge departure failed to cancel the attempt")
    assert(cancelled.state[:commitments].empty? && cancelled.state[:reveals].empty?,
      "#{judge_mode}: cancelled attempt retained private data")
    row = f.departures('Bob').first
    assert(row && row['__controller'] == true && row['__authority_user'] == 'Bob',
      "#{judge_mode}: successor did not authenticate the removal")
    now = cancelled.state[:resume_at]
    successor.instance_variable_get(:@clock).define_singleton_method(:now) { |_session| now }
    successor.instance_variable_set(:@covered, -> { true })
    f.step('Bob', count: 3)
    next_round = f.replay('Bob')
    assert(next_round.state[:phase] == :answering && next_round.state[:judge] == 'Bob',
      "#{judge_mode}: successor failed to start and judge the replacement attempt")
    assert(next_round.state[:active_players] == %w[Carol Dave] && next_round.state[:attempt] == before.state[:attempt] + 1,
      "#{judge_mode}: replacement attempt kept an old participant or private envelope identity")
    assert(!next_round.finished? && !next_round.winner, "#{judge_mode}: departure manufactured a victory")
  ensure
    f.close
  end
end

# A spectator may become the host without joining the original game seats.
# Changing ownership alone keeps the current judge. Once that judge leaves,
# the observer successor must be able to judge and commit a full later round.
f = NativeCategoriesMembershipFixture.new(judge_mode: 'master')
begin
  f.h.add_client('Watcher')
  assert(f.h.join('Watcher'), 'Observer successor could not join')
  f.h.as('Watcher') { f.h.transports['Watcher'].set_observer(f.h.table, true, actor: 'Watcher') }
  view = f.h.view('Alice')
  view.transfer_ownership(view.participants.find { |participant| participant.user == 'Watcher' })
  before = f.replay('Watcher')
  successor = f.step('Watcher', count: 3, covered: true)
  assert(f.departures('Watcher').empty? && f.replay('Watcher').state[:judge] == 'Alice' &&
    f.replay('Watcher').state[:attempt] == before.state[:attempt],
    'Ownership transfer alone removed the still-present permanent judge')
  f.leave('Alice')
  f.step('Watcher', count: 3)
  cancelled = f.replay('Watcher')
  assert(cancelled.state[:phase] == :round_complete && cancelled.state[:permanent_judge] == 'Watcher',
    'Observer successor did not become the permanent judge after the old judge left')
  now = cancelled.state[:resume_at]
  successor.instance_variable_get(:@clock).define_singleton_method(:now) { |_session| now }
  f.step('Watcher', count: 3)
  next_round = f.replay('Watcher')
  assert(next_round.state[:judge] == 'Watcher' && next_round.state[:active_players] == %w[Bob Carol Dave],
    'Observer judge was assigned an answerer seat or displaced an existing contestant')
  submit_as = lambda do |user, selection = nil|
    participant_runner = f.runner(user)
    current = f.replay(user)
    session = f.h.repositories.fetch(user).snapshot_for(f.h.session).session
    selection ||= f.game.automatic_action(current, user, context: participant_runner.send(:context))
    f.h.as(user) do
      participant_runner.submit(session: session, replay: current, actor: user, selection: selection)
    end
  end
  %w[Bob Carol Dave].each do |user|
    result = submit_as.call(user, {'kind' => 'answer_sheet', 'action' => 'submit',
      'answers' => {'country' => "#{user}-country", 'city' => "#{user}-city"}})
    assert(result.first == :ok, 'Answerer could not submit under the observer host epoch')
  end
  f.step('Watcher', count: 3)
  assert(f.replay('Watcher').state[:phase] == :revealing, 'Observer host failed to close submitted answers')
  %w[Bob Carol Dave].each do |user|
    assert(submit_as.call(user).first == :ok, 'Answerer could not reveal under the observer host epoch')
  end
  f.step('Watcher', count: 3)
  review = f.replay('Watcher')
  assert(review.state[:phase] == :review, 'Observer host failed to open judging')
  decisions = f.game.send(:review_items, review.state).to_h { |item| [item[:id], 'unique'] }
  selection = {'kind' => 'review', 'action' => 'finish', 'decisions' => decisions}
  assert(f.game.moderator_action?(selection), 'Review sheet is not exposed to the current moderator')
  result = f.h.as('Watcher') do
    session = f.h.repositories.fetch('Watcher').snapshot_for(f.h.session).session
    # Match GameScreen#selected_action_actor: a host moderation action uses
    # the initial controller seat and keeps Watcher as authenticated authority.
    successor.submit(session: session, replay: review, actor: review.players.first,
      selection: selection, controller: true)
  end
  assert(result.first == :ok, 'Observer permanent judge could not submit the review sheet')
  f.step('Watcher')
  scored = f.replay('Watcher')
  assert(scored.state[:phase] == :round_complete && scored.state[:scores].slice('Bob', 'Carol', 'Dave').values == [4, 4, 4],
    "Observer judge review failed: #{scored.state.slice(:phase, :scores, :completed_rounds).inspect}")
  assert(!scored.state[:scores].key?('Watcher'), 'Observer permanent judge gained a fake contestant score')
ensure
  f.close
end

# The first round stays immutable. The original host leaves while a different
# participant is judging round two; only the absent answerer's work disappears.
f = NativeCategoriesMembershipFixture.new
begin
  f.review.score
  scored = f.replay
  f.contexts['Alice'].now = scored.state[:resume_at]
  f.h.submit('Alice', context: f.contexts['Alice'])
  second = f.replay
  assert(second.state[:judge] == 'Bob', 'Second-round judge setup failed')
  f.leave('Alice')
  f.step('Bob', count: 3)
  current = f.replay('Bob')
  assert(current.state[:phase] == :answering && current.state[:attempt] == second.state[:attempt],
    'Departure of the host cancelled the round belonging to another judge')
  assert(current.state[:judge] == 'Bob' && current.state[:active_players] == %w[Carol Dave],
    'Departure changed the existing judge or kept the departed answerer')
  assert(current.state[:scores] == scored.state[:scores] && current.history.first(scored.history.length) == scored.history,
    'Host departure rewrote completed round points/history')
ensure
  f.close
end

f = NativeCategoriesMembershipFixture.new(users: %w[Alice Bob])
begin
  f.leave('Bob')
  f.step('Alice', count: 4)
  replay = f.replay
  snapshot = f.h.repositories['Alice'].snapshot_for(f.h.session)
  assert(replay.state[:phase] == :interrupted && !replay.finished? && !replay.winner && !replay.draw,
    'The last remaining participant received an artificial game result')
  assert(snapshot.session['__aborted'] == true, 'Insufficient membership did not terminate the native game')
  assert(f.departures('Alice').length == 1, 'Interrupted game repeated its departure action')
  activity = TableActivityRepository.new(server_tables: Object.new, transport: f.h.transports['Alice'])
  entries = activity.entries_for(f.h.table)
  aborts = entries.select { |entry| entry.kind == 'game_aborted' }
  assert(aborts.length == 1 && aborts.first.reason == 'not_enough_players',
    'Automatic native abort lost its specific cause or was duplicated')
  room_data = f.h.transports['Alice'].room_snapshot(f.h.table)
  lifecycle = GameRoomLifecycle::State.new(room: LobbyRepository::TableSnapshot.new(**room_data),
    game_snapshot: snapshot, game: f.game, replay: replay, players: replay.players, activity_entries: entries)
  assert(lifecycle.waiting? && !lifecycle.finished? && lifecycle.history == replay.history,
    'Returning to the waiting room erased interrupted match history or invented a result')
  merged = activity.merged_history_entries(game_entries: lifecycle.history, game_events: replay.accepted_events,
    activity_entries: entries, game_name: ->(_id) { f.game.name }).map(&:text)
  reason = 'The game was interrupted because fewer than two participants remain.'
  assert(merged.count(reason) == 1, 'The merged waiting-room history repeats or omits the real interruption reason')
  assert(merged.none? { |text| text.include?('Alice ended the game') }, 'Automatic interruption was attributed to a manual host action')
  score_text = replay.history.find { |entry| entry.kind == :final_scores }.text
  assert(merged.count(score_text) == 1, 'The final score summary disappeared or was repeated in the waiting room')
ensure
  f.close
end

# This path must not accidentally bypass tournament grace/forfeit policy.
marker = {'publication_ref' => {'author' => 'alice', 'publication_key' => 'membership-contract'},
  'schedule_id' => 'a' * 64, 'match_id' => 'b' * 64, 'leg' => 1}
f = NativeCategoriesMembershipFixture.new(users: %w[Alice Bob Carol], tournament: marker)
begin
  f.leave('Bob')
  f.step('Alice', count: 4)
  assert(f.departures('Alice').empty? && f.replay.state[:departed_players].empty?,
    'Ordinary immediate departure policy removed a tournament participant')
  assert(f.replay.state[:active_players].include?('Bob'), 'Tournament return allowance lost its private participant')
ensure
  f.close
end

puts 'PASS native Categories membership runner: idle/covered, answerer leave/return, native authority, rotating/permanent judge succession, preserved completed history, unrelated judge, interrupted boundary and tournament exemption'
