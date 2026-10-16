# encoding: UTF-8
require_relative '../support/ft2_runtime_support'
include FT2RuntimeSupport
context, record = execution_fixture(File.basename(ENV.fetch('ENTRY_EVIDENCE')))
rows = []
actor_backend(context, 'Ala') do |backend, authority, directory|
  registry = Object.new
  callback = nil
  registry.define_singleton_method(:build) do |id|
    action, callback = callback, nil
    action&.call
    REGISTRY.build(id)
  end
  facade = T::LocalFixedTeamExecution.new(plan_backend: backend, plan_directory: directory,
    source_identity: context.provider.backend_identity, context: authority, registry: registry,
    clock: -> { 1792058401 }, policy_ref: 'jawna-polityka-proby-ft2a', expires_at: record['evidence']['plan']['matches'].first['windows'].first['closes'] - 1)
  record['evidence']['plan']['matches'].each_with_index do |match, index|
    selectors = {evidence: record['evidence'], expected_source: record['expected_source'], match_id: match['match_id'],
      leg: match['leg'], window_id: match['windows'].first['id'], registry: REGISTRY}
    expected_request = T::CoordinationRequest.from_execution_plan(**selectors).to_h
    expected_native = T::FixedTeamNativePayload.from_execution_plan(**selectors).to_h
    id, window, intent = match['match_id'].dup, match['windows'].first['id'].dup, 'ft2a-plan'.dup
    changed = false
    callback = -> do
      worker = Thread.new do
        id.replace(record['evidence']['plan']['matches'][(index + 1) % 6]['match_id'])
        window.replace(match['windows'].last['id'])
        intent.replace('nieistniejacy-caller')
      end
      worker.value
      changed = true
    end
    actual = facade.select(intent_id: intent, match_id: id, leg: match['leg'], window_id: window)
    assert(changed && !id.frozen? && !window.frozen? && !intent.frozen?)
    assert_equal(record, actual[:record])
    assert_equal(expected_request, actual[:request].to_h, 'Pierwotny request przed callbackiem')
    assert_equal(expected_native, actual[:native].to_h, 'Pierwotny native przed callbackiem')
    rows << {index: index, record: actual[:record], expected_request: expected_request, actual_request: actual[:request].to_h,
      expected_native: expected_native, actual_native: actual[:native].to_h, caller: [id, window, intent]}
  end
end
assert_equal(6, rows.size)
assert_equal([1, 2], rows.map { |row| row[:actual_request]['leg'] }.uniq)
oracle_file('selectors.json', rows)
puts 'GREEN: wszystkie trzy pary i dwa legi, exact rekord/request/native, odłączone selektory'
