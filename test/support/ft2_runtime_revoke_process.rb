# encoding: UTF-8
require_relative 'ft2_runtime_cold'
include FT2RuntimeCold
directory, stage = ARGV
context = TournamentPublicServiceSupport::Context.new(directory, 'Organizator'); context.now = 201
record = nil
with_backend(context) { |backend| record = backend.readback(intent_id: 'ft2a-plan') }
actor = record['evidence']['plan']['matches'].first['players'].first['username']
before = state(context)
runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  epoch = facade.coordinator_epoch
  facade.revoke_coordinator(expected_epoch: epoch)
end
# Rzeczywisty powrót tego samego aktora i gotowości, bez ręcznej edycji epoki/grantu.
runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  assert_equal(:confirmed, facade.declare(availability: 'withdrawn', expected_revision: 1)[:state])
end
runtime_execution(context, record, actor, provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 2)[:state])
end
after = state(context)
assert_equal(before['executions'].values.first['epoch'] + 1, after['executions'].values.first['epoch'])
assert_equal(nil, after['executions'].values.first['grant'])
assert_equal(before['native'], after['native'])
oracle_file("revoke-child-#{stage}-#{Process.pid}.json", {pid: Process.pid, before: before, after: after})
puts "B: revoke/withdraw/ready, trwała nowa epoka; brak renew/takeover"
