require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport

with_fixture(game: 'reversi', names: %w[Alpha Beta], rematch: false) do |fixture|
  record = start_individual_match(fixture, intent_id: 'reversi-complete')
  people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }
  actor = people.first['username']
  count = 0
  finished = false
  # Choose the first legal placement supplied by the game; never calculate
  # captures or manufacture events/results in this tournament test.
  65.times do
    with_individual_execution(fixture, record, actor) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      if status['phase'] == 'finished'
        finished = true
        next
      end
      assert_equal(actor, status['current_player'])
      selection = status['actions'].find { |action| action['kind'] == 'grid' } || status['actions'].first
      assert(selection, 'unfinished game must supply a legal action')
      effect = execution.local_game(action: :local_game_move, operation_id: "reversi-#{count}",
        revision: status['revision'], move_selection: selection)
      assert_equal(:confirmed, effect[:state], effect.inspect)
      count += 1
      assert_equal(count, effect[:status]['event_count'])
      assert_equal(effect[:effect], execution.local_game(action: :local_game_move, operation_id: "reversi-#{count - 1}",
        revision: status['revision'], move_selection: selection)[:effect])
      finished = effect[:status]['phase'] == 'finished'
      actor = effect[:status]['current_player'] unless finished
    end
    break if finished
  end
  assert(finished, 'bounded real game must finish')
  assert(count > 20, 'exercise a complete board game')
  winner_seats = nil
  with_individual_execution(fixture, record, people.first['username']) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    effect = execution.local_game(action: :finalize_local_game, revision: status['revision'])
    assert_equal(:confirmed, effect[:state], effect.inspect)
    summary = effect[:effect]['summary']
    assert(summary['draw'] || summary['winners'].size == 1)
    assert_equal(nil, summary['scores'], 'Reversi exported unsupported tournament small points')
    assert_equal(people.map { |person| person['account'] }.sort, summary.fetch('participants').sort)
    assert(summary['winners'].all? { |name| summary.fetch('participants').include?(name) }, 'Winner is outside the completed game')
    winner_seats = people.each_index.select { |seat| summary['winners'].include?(people[seat]['account']) }.join(',')
    assert_equal(true, execution.progress['complete'])
  end
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  bytes = File.binread(path)
  assert_equal({}, JSON.parse(bytes)['busy'])
  probe = File.expand_path('../support/tournament_game_finish_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, probe, fixture.directory, 'reversi', 'reversi-complete', count.to_s, winner_seats],
    err: [:child, :out], &:read)
  assert($?.success?, output)
  assert_equal(bytes, File.binread(path))
  puts "PASS tournament Reversi: #{count} real moves, idempotent receipts, game-owned result, busy release and cold archive"
end
