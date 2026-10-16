# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
path = File.expand_path('../../lib/tournaments/local_fixed_team_execution.rb', __dir__)
require path if File.file?(path)
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
expected = [%w[Beata Bartek Anna Ala], %w[Ala Anna Cezary Celina], %w[Celina Cezary Beata Bartek],
  %w[Anna Ala Beata Bartek], %w[Cezary Celina Ala Anna], %w[Beata Bartek Celina Cezary]]
assert_equal(expected, record['evidence']['plan']['matches'].map { |match| match['players'].map { |person| person['username'] } })
oracle_file('accepted.json', record)
assert(T.const_defined?(:LocalFixedTeamExecution, false), 'RED_FT2A_KOMPOZYCJA: brak fasady gotowości przyjętego FT1')
assert(T::LocalFixedTeamExecution.respond_to?(:new), 'RED_FT2A_KOMPOZYCJA: brak wejścia kompozycji')
selections = []
execution_for(context, record, 'Ala') do |facade|
  record['evidence']['plan']['matches'].each_index do |index|
    selected = select_match(facade, record, index)
    assert_equal(record, selected.fetch(:record), 'Pełny exact rekord producenta')
    assert_equal(expected[index], selected.fetch(:native).to_h['players'])
    assert_equal(false, selected.fetch(:native).to_h['start_allowed'])
    assert_equal(false, selected.fetch(:native).to_h['dispatch_allowed'])
    selections << {record: selected[:record], request: selected[:request].to_h, native: selected[:native].to_h}
  end
end
receipts = []
expected.first.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    result = facade.declare(availability: 'ready', expected_revision: 0)
    assert_equal(:confirmed, result[:state], 'RED_FT2A_GOTOWOSC: własne ready przez rzeczywisty ReadinessService')
    current = facade.current
    assert_equal('ready', current[:current]['state'])
    assert_equal(1, current[:current]['ready_revision'])
    assert_equal(actor.downcase, result[:receipt]['operation']['account'])
    receipts << result
  end
end
execution_for(context, record, 'Ala') do |facade|
  select_match(facade, record)
  result = facade.declare(availability: 'withdrawn', expected_revision: 1)
  assert_equal(:confirmed, result[:state])
  assert_equal('withdrawn', facade.current[:current]['state'])
  receipts << result
end
execution_for(context, record, 'Organizator') do |facade|
  select_match(facade, record)
  result = facade.declare(availability: 'ready', expected_revision: 0)
  assert_equal(:not_participant, result[:reason])
end
oracle_file('readiness.json', {selections: selections, receipts: receipts})
puts 'GREEN: nowa fasada odczytuje FT1, deklaruje własne ready/withdraw przez rzeczywisty serwis; bez koordynacji i Start'
