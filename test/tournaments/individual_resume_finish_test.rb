require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport
with_fixture(game: 'tic_tac_toe', names: %w[Alpha Beta], rematch: false) do |fixture|
  record = start_individual_match(fixture, intent_id: 'resume-complete')
  people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }
  commands = [[0,0], [0,1], [1,0], [1,1], [2,0]].each_with_index.map do |(x,y), index|
    {'actor' => people[index % 2]['username'], 'id' => "resume-#{index}", 'before_count' => index,
      'selection' => {'kind' => 'grid', 'action' => 'select', 'x' => x, 'y' => y}}
  end
  commands.first(2).each do |command|
    with_individual_execution(fixture, record, command['actor']) do |execution|
      status = execution.local_game(action: :local_game_status)[:status]
      result = execution.local_game(action: :local_game_move, operation_id: command['id'],
        revision: status['revision'], move_selection: command['selection'])
      assert_equal(:confirmed, result[:state], result.inspect)
    end
  end
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  before = JSON.parse(File.binread(path))
  assert_equal(2, before['busy'].size)
  old = before['executions'].values.first
  assert_equal(nil, old['result'])
  probe = File.expand_path('../support/tournament_resume_moves_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, probe, fixture.directory, 'tic_tac_toe', 'resume-complete', JSON.generate(commands.drop(2))],
    err: [:child, :out], &:read)
  assert($?.success?, output)
  after = JSON.parse(File.binread(path))
  current = after['executions'].values.first
  assert_equal({}, after['busy'])
  assert_equal(old['start'], current['start'])
  assert_equal(old['target'], current['target'])
  assert_equal(old['epoch'], current['result']['epoch'])
  assert_equal(old['epoch'] + 1, current['epoch'])
  assert_equal(old['moves'], current['moves'].first(2))
  assert_equal(5, current['moves'].size)
  assert_equal([people.first['account']], current['result']['summary']['winners'])
  puts 'PASS restart recovery: same session and epoch, immutable prior receipts, busy held until actual finish'
end
