require_relative '../support/tournament_individual_execution'
include TournamentIndividualExecutionSupport

# Only this isolated test process replaces fresh dice. Production replay still
# consumes the recorded randomness through the ordinary session runner.
GameRoomRandom::LocalSecureSource.prepend(Module.new do
  def roll(count:, sides:)
    raise 'unexpected dice request' unless count == 6 && sides == 6
    GameRoomRandom::Roll.new(values: [1,2,3,4,5,6], sides: sides, source: source_name, proof: nil)
  end
end)

with_fixture(game: 'farkle', names: %w[Alpha Beta Gamma], players_per_match: 3, rematch: false,
  game_options: {'score_limit' => 200, 'turn_minimum' => 0, 'entry_minimum' => 0, 'farkle_rules_version' => 2}) do |fixture|
  record = start_individual_match(fixture, intent_id: 'farkle-complete')
  people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }
  people.each_with_index do |person, seat|
    with_individual_execution(fixture, record, person['username']) do |execution|
      [{'action' => 'roll'}, {'action' => 'keep', 'indices' => '0,1,2,3,4,5'}, {'action' => 'bank'}].each_with_index do |selection, step|
        status = execution.local_game(action: :local_game_status)[:status]
        effect = execution.local_game(action: :local_game_move, operation_id: "dice-#{seat}-#{step}",
          revision: status['revision'], move_selection: selection.merge('kind' => 'dice'))
        assert_equal(:confirmed, effect[:state], effect.inspect)
        assert_equal(seat * 3 + step + 1, effect[:status]['event_count'])
      end
    end
  end
  with_individual_execution(fixture, record, people.first['username']) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal('finished', status['phase'])
    result = execution.local_game(action: :finalize_local_game, revision: status['revision'])
    assert_equal(:confirmed, result[:state], result.inspect)
    summary = result[:effect]['summary']
    assert_equal(true, summary['draw'])
    assert_equal([], summary['winners'])
    assert_equal([200,200,200], summary['scores'].values.sort)
    assert_equal(true, execution.progress['complete'])
  end
  path = File.join(fixture.directory, 'k02/individual-v1/execution-v1/state.json')
  bytes = File.binread(path)
  assert_equal({}, JSON.parse(bytes)['busy'])
  probe = File.expand_path('../support/tournament_game_finish_probe.rb', __dir__)
  output = IO.popen([RbConfig.ruby, probe, fixture.directory, 'farkle', 'farkle-complete', '9', ''], err: [:child, :out], &:read)
  assert($?.success?, output)
  assert_equal(bytes, File.binread(path))
end
puts 'PASS tournament Farkle: three actual turns, recorded dice, game-owned tie, scores and busy release'
