# encoding: UTF-8
require_relative '../support/ft2_runtime_support'
include FT2RuntimeSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
observe_change(context, record)
actor = record['evidence']['plan']['matches'].first['players'].first['username']
path = state_path(context)
rows = []
[:reconcile, :request_match].each do |action|
  before = File.file?(path) ? File.binread(path) : nil
  execution_for(context, record, actor, native_provider: TournamentFixedTeamNativeService.new) do |facade|
    historical_select(facade, record)
    result = outcome { facade.public_send(action) }
    after = File.file?(path) ? File.binread(path) : nil
    rows << {action: action, result: result, before: before, after: after}
    oracle_file("no-effect-#{action}.json", rows.last)
    assert_equal(before, after, 'RED_FT2A_RUNTIME_NO_EFFECT: odczyt historyczny/nieaktualny current nie może zapisać execution')
    assert_equal(action == :reconcile ? :unknown : :blocked, result[:state])
    assert_equal(action == :reconcile ? :no_original_operation : :source_changed, result[:reason])
  end
end
puts 'GREEN: brak pierwotnej operacji pozostaje unknown; current odmawia przed zapisem execution'
