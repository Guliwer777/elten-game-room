# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
class FT2C08AfterCommit < TournamentFixedTeamNativeService
  attr_reader :receipt
  def initialize(error); @error = error; end
  def committed(receipt:)
    @receipt = receipt
    raise @error, cause: @error.cause
  end
end
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
players = record['evidence']['plan']['matches'].first['players'].map { |p| p['username'] }
players.each do |actor|
  execution_for(context, record, actor) do |facade|
    select_match(facade, record)
    assert_equal(:confirmed, facade.declare(availability: 'ready', expected_revision: 0)[:state])
  end
end
cause = IOError.new('Pierwotna przyczyna')
primary = begin
  raise T::Publication::Invalid.new(:json_budget), cause: cause
rescue T::Publication::Invalid => error
  error
end
backtrace = primary.backtrace.dup
provider = FT2C08AfterCommit.new(primary)
seen = nil
execution_for(context, record, players.first, native_provider: provider) do |facade|
  select_match(facade, record)
  begin
    seen = facade.request_match
  rescue Exception => error
    seen = error
  end
end
path = File.join(context.directory, 'plany/fixed-teams-v1/execution-ft2-v1/state.json')
state = JSON.parse(File.binread(path))
actual = {same_primary: seen.equal?(primary), same_cause: seen.is_a?(Exception) && seen.cause.equal?(cause),
  same_backtrace: seen.is_a?(Exception) && seen.backtrace == backtrace,
  durable_receipt: state['executions'].values.first['operations']['create_bind'].eql?(provider.receipt), creates: state['native']['creates'].size}
expected = {same_primary: true, same_cause: true, same_backtrace: true, durable_receipt: true, creates: 1}
oracle_file('ft2_c08_after_commit.json', {expected: expected, actual: actual, result: seen.is_a?(Exception) ? seen.class.name : seen, state: state})
assert_equal(expected, actual, 'RED_FT2A_C08_AFTER_COMMIT: błąd programu po commit nie może stać się blocked/json_budget')
execution_for(context, record, players.first, native_provider: TournamentFixedTeamNativeService.new) do |facade|
  select_match(facade, record)
  result = facade.reconcile
  assert_equal(:bound, result[:state])
  assert_equal(provider.receipt['operation_id'], result[:operation_id])
end
assert_equal(1, JSON.parse(File.binread(path))['native']['creates'].size)
puts 'GREEN C08: exact primary/cause/backtrace po skutku i ten sam receipt bez drugiego create'
