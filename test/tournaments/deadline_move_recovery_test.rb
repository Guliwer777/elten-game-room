require_relative '../support/tournament_dispatch'
include TournamentDispatchSupport

T::LocalIndividualExecutionStorage.prepend(Module.new do
  def write(document, receipt: nil)
    value = super
    if $deadline_lost_move_reply && receipt.is_a?(Hash) && receipt['kind'] == 'move'
      $deadline_lost_move_reply = false
      raise T::LocalFixedTeamExecutionStorage::Unconfirmed.new(attempt_id: 'deadline-lost-move', receipt: receipt)
    end
    value
  end
end)

with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  backend = fixture.backend
  record = backend.accept(preview: backend.preview(publication_ref: fixture.reference,
    base_seats: fixture.base, intent_id: 'deadline-move-recovery'))
  intent = record['preview']['intent_id']
  window = record['evidence']['plan']['matches'].first['windows'].first
  fixture.now = window['opens'] + 1
  with_dispatch(fixture, record, 'Organizator') { |d| d.configure(intent_id: intent, max_tables: 1) }
  %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| d.available(intent_id: intent, available: true) } }
  2.times { %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| d.advance(intent_id: intent) } } }
  %w[Alpha Beta].each { |name| with_dispatch(fixture, record, name) { |d| assert_equal(:confirmed, d.accept(intent_id: intent)[:state]) } }
  with_dispatch(fixture, record, 'Alpha') { |d| assert_equal(:confirmed, d.advance(intent_id: intent)[:state]) }
  row = dispatch_state(fixture)['executions'].values.first
  first_player, second_player = row['request']['players'].sort_by { |person| person['seat'] }.map { |person| person['username'] }
  select_match = lambda do |execution|
    request = row['request']
    execution.select(intent_id: intent, match_id: request['match_id'], leg: request['leg'], window_id: request['window']['id'])
  end
  revision = nil
  selection = {'kind' => 'grid', 'action' => 'select', 'x' => 0, 'y' => 0}
  with_individual_execution(fixture, record, first_player, clock: -> { fixture.now }) do |execution|
    select_match.call(execution)
    revision = execution.local_game(action: :local_game_status)[:status]['revision']
    $deadline_lost_move_reply = true
    effect = execution.local_game(action: :local_game_move, operation_id: 'before-deadline', revision: revision, move_selection: selection)
    assert_equal(:uncertain, effect[:state], effect.inspect)
  end
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  before = File.binread(path)
  fixture.now = window['closes']
  with_individual_execution(fixture, record, first_player, clock: -> { fixture.now }) do |execution|
    select_match.call(execution)
    effect = execution.local_game(action: :local_game_move, operation_id: 'before-deadline', revision: revision, move_selection: selection)
    assert_equal(:confirmed, effect[:state], effect.inspect)
    assert_equal('before-deadline', effect[:effect]['id'])
  end
  with_individual_execution(fixture, record, row['coordinator'], clock: -> { fixture.now }) do |execution|
    select_match.call(execution)
    finished = execution.local_game(action: :finalize_local_game, revision: execution.local_game(action: :local_game_status)[:status]['revision'])
    assert_equal(:blocked, finished[:state])
    assert_equal(:game_not_finished, finished[:reason])
  end
  with_individual_execution(fixture, record, second_player, clock: -> { fixture.now }) do |execution|
    select_match.call(execution)
    current = execution.local_game(action: :local_game_status)[:status]
    effect = execution.local_game(action: :local_game_move, operation_id: 'after-deadline', revision: current['revision'],
      move_selection: {'kind' => 'grid', 'action' => 'select', 'x' => 1, 'y' => 0})
    assert_equal(:blocked, effect[:state])
    assert_equal(:outside_window, effect[:reason])
  end
  assert_equal(before, File.binread(path))
  state = dispatch_state(fixture)
  assert_equal(1, state['executions'].values.first['moves'].size)
  assert_equal(2, state['busy'].size)
end
puts 'PASS deadline move recovery: lost reply reconciled after expiry without a new move, result or reservation release'
