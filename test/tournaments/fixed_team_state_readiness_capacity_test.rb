# encoding: UTF-8
require_relative '../support/tournament_fixed_team_execution'
require_relative '../../lib/tournaments/local_fixed_team_execution'
include TournamentFixedTeamExecutionSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
player = record['evidence']['plan']['matches'].first['players'].first['username']
execution_for(context, record, player) do |facade|
  select_match(facade, record)
  assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
end
path = File.join(context.directory, 'plany', 'fixed-teams-v1', 'execution-ft2-v1', 'state.json')
document = JSON.parse(File.binread(path))
seed = document['readiness'].first
# Syntetyczny, semantycznie legalny stan retencji; FT1 pozostaje rzeczywiście przyjęty.
(1...2048).each do |index|
  prior = seed['operation']
  request = prior['request'].merge('expected_ready_revision' => index)
  operation = T::ReadinessContract.operation(request, prior['account'], prior['accepted_match'], SecureRandom.uuid)
  receipt = seed.merge('operation' => operation, 'request_digest' => operation['request_digest'],
    'result' => seed['result'].merge('ready_revision' => index + 1))
  document['readiness'] << T::ReadinessContract.response!(receipt, operation)
end
bytes = JSON.generate(document); File.binwrite(path, bytes)
claims = []; result = current = nil
trace = TracePoint.new(:call) { |p| claims << p.method_id if p.defined_class == T::ReadinessJournal && p.method_id == :claim }
execution_for(context, record, player) do |facade|
  select_match(facade, record)
  current = facade.current
  assert_equal(2048, current[:current]['ready_revision'], 'Dodatni odczyt legalnego pełnego magazynu bez migracji')
  begin
    trace.enable(target_thread: nil)
    result = facade.declare(availability: 'withdrawn', expected_revision: 2048)
  ensure
    trace.disable
  end
end
oracle_file('state-readiness-capacity.json', {fixture: 'syntetyczna retencja legalnych receipts, realny FT1', current: current,
  result: result, claims: claims, bytes: bytes.bytesize, before: document, after: JSON.parse(File.binread(path))})
assert(result[:state] == :blocked && result[:reason] == :sandbox_limit && claims.empty? && File.binread(path) == bytes.b,
  'RED_FT2A_RETENTION_BEFORE_CLAIM: wyczerpany limit całego state musi odmówić przed nowym claim')
puts 'GREEN: pełne legalne 2048 receipts czytelne, kolejna mutacja odmawia przed claim'
