# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
context, record, _players, path, healthy = c08_bound_fixture
variants = {
  repeated_operation_uuid: ->(d) do
    e = d['executions'].values.first
    create = e['operations']['create_bind']
    id = e['operations']['reserve']['operation_id']
    create['operation_id'] = create['operation']['operation_id'] = id
    e['target'] = T::FixedTeamBoundTarget.build(record: record, response: create, readback: e['target']['readback'], registry: REGISTRY).to_h
  end,
  repeated_receipt_uuid: ->(d) do
    e = d['executions'].values.first
    create = e['operations']['create_bind']
    create['receipt'] = e['operations']['reserve']['receipt']
    e['target'] = T::FixedTeamBoundTarget.build(record: record, response: create, readback: e['target']['readback'], registry: REGISTRY).to_h
  end,
  phantom_invalidated_grant: ->(d) { d['readiness'].first['result']['invalidated_grants'] = [SecureRandom.uuid] },
  live_grant_after_new_revision: ->(d) do
    receipt = JSON.parse(JSON.generate(d['readiness'].first))
    old = receipt['operation']
    request = old['request'].merge('expected_ready_revision' => 1, 'availability' => 'withdrawn')
    receipt['operation'] = T::ReadinessContract.operation(request, old['account'], old['accepted_match'], SecureRandom.uuid)
    receipt['request_digest'] = receipt['operation']['request_digest']
    receipt['result'].merge!('ready_revision' => 2, 'state' => 'withdrawn')
    d['readiness'] << receipt
  end
}
c08_corruption(context, record, path, healthy, variants)
puts 'GREEN C08: globalne operacje, receipts i relacje unieważnienia gotowości'
