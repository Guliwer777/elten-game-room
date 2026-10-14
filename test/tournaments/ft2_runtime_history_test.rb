# encoding: UTF-8
require_relative '../support/ft2_runtime_support'
include FT2RuntimeSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
all_ready(context, record)
player = record['evidence']['plan']['matches'].first['players'].first['username']
provider = TournamentFixedTeamExecutionProcess::LosingService.new
execution_for(context, record, player, native_provider: provider) do |facade|
  select_match(facade, record)
  begin
    facade.request_match
  rescue TournamentFixedTeamExecutionProcess::LostResponse => error
    assert(error.equal?(provider.failure))
  end
end
assert(provider.receipt, 'Rzeczywisty skutek przed utratą odpowiedzi')
observe_change(context, record)
expected = state(context)
current = nil
actual = nil
execution_for(context, record, player, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  current = outcome { select_match(facade, record) }
  assert_equal(:source_changed, current[:reason], 'Nowe skutki wymagają aktualnego FT1')
  actual = outcome do
    selected = historical_select(facade, record, intent: 'ft2-runtime-alias')
    assert_equal(record, selected[:record])
    facade.reconcile
  end
end
oracle_file('history.json', {expected: expected, actual: actual.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v }, current: current, record: record})
assert_equal(:bound, actual[:state], 'RED_FT2A_RUNTIME_HISTORY: zimny wybór historyczny nie może wymagać current')
assert_equal(provider.receipt['operation_id'], actual[:operation_id])
assert_equal(expected['executions'].values.first['target'], actual[:target].to_h)
assert_equal(expected, state(context))
puts 'GREEN: nowa obserwacja/alias blokuje current, lecz nie uzgodnienie pierwotnego skutku'
