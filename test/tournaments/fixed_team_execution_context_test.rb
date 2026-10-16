# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../support/tournament_fixed_team_native_service'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
player = record['evidence']['plan']['matches'].first['players'].first['username']
path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
checks = []
[:actor, :backend, :session, :lease, :program, :runtime].each do |event|
  execution_for(context, record, player, native_provider: TournamentFixedTeamNativeService.new) do |facade, session, program, entry|
    select_match(facade, record)
    before = File.exist?(path) ? File.binread(path) : nil
    case event
    when :actor
      session.choose_actor('InnaOsoba'); session.choose_actor(player)
    when :backend
      original = session.backend_events.snapshot[:value]
      session.change_backend('inny_backend'); session.change_backend(original)
    when :session then session.close
    when :lease then entry.close
    when :program then program.finalize
    when :runtime then TournamentEntryContextTest::Program.app_runtime.close
    end
    result = facade.declare(availability: 'ready', expected_revision: 0)
    assert_equal(:blocked, result[:state])
    failed = nil
    begin
      outcome = facade.request_match
      failed = outcome[:state] == :blocked
    rescue T::ReadinessContract::Blocked
      failed = true
    end
    assert(failed, 'Stary wykonawca odcięty przez zdarzenie')
    assert_equal(before, File.exist?(path) ? File.binread(path) : nil)
    checks << {event: event, ready: result, coordination_refused: failed}
  end
end
execution_for(context, record, player, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  assert(facade.respond_to?(:coordinator_epoch) && facade.respond_to?(:revoke_coordinator),
    'RED_FT2A_EPOKI: brak trwałego producenta cofnięcia koordynatora')
  epoch = facade.coordinator_epoch
  facade.revoke_coordinator(expected_epoch: epoch)
  before = File.binread(path)
  failed = nil
  begin
    result = facade.request_match
    failed = result[:state] == :blocked
  rescue T::CoordinationContract::Blocked, T::ReadinessContract::Blocked
    failed = true
  end
  assert(failed, 'Cofnięta epoka odcina stary obiekt, nie tylko jego aktualne wywołanie')
  assert_equal(before, File.binread(path))
end
oracle_file('context-events.json', checks)
puts 'GREEN: rzeczywiste zmiany kontekstu i trwałe cofnięcie epoki blokują stary obiekt'
