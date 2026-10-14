require_relative 'tournament_individual_execution'
include TournamentIndividualExecutionSupport
fixture = TournamentLocalExecutionPlanSupport::Fixture.new(ARGV.fetch(0), game: ARGV.fetch(1), reopen: true)
begin
  record = fixture.backend.readback(intent_id: ARGV.fetch(2))
  people = record['evidence']['plan']['matches'].first['players'].sort_by { |person| person['seat'] }
  winners = ARGV.fetch(4).split(',').map do |unit|
    if unit.match?(/\A[0-9]+\z/)
      people.fetch(Integer(unit))
    else
      people.find { |person| person['account'] == unit } || raise('Expected winner is outside the accepted roster')
    end
  end
  with_individual_execution(fixture, record, people.first['username']) do |execution|
    status = execution.local_game(action: :local_game_status)[:status]
    assert_equal('finished', status['phase'])
    assert_equal(Integer(ARGV.fetch(3)), status['event_count'])
    assert_equal(winners.map { |person| person['account'] }, status['result']['summary']['winners'])
    assert_equal(true, status['result']['summary']['draw']) if winners.empty?
    assert_equal(true, execution.progress['complete'])
    execution.progress['standings'].each do |row|
      assert_equal(row['wins'] * 2 + row['draws'], row['points'])
      assert(row['place'].is_a?(Integer) && row['place'] > 0)
    end
  end
  puts 'PASS cold tournament game result'
ensure
  fixture.close
end
