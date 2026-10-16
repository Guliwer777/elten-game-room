# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
context, record, players, path, healthy = c08_bound_fixture
variants = {
  null_receipt: ->(d) { d['readiness'][0] = nil },
  false_receipt: ->(d) { d['readiness'][0] = false },
  null_result: ->(d) { d['readiness'][0]['result'] = nil },
  fractional_time: ->(d) { d['readiness'][0]['result']['server_time'] = 1.0 },
  regressed_time: ->(d) do
    seed = d['readiness'][0]
    prior = seed['operation']
    operation = T::ReadinessContract.operation(prior['request'].merge('expected_ready_revision' => 1), prior['account'], prior['accepted_match'], SecureRandom.uuid)
    receipt = seed.merge('operation' => operation, 'request_digest' => operation['request_digest'],
      'result' => seed['result'].merge('ready_revision' => 2, 'server_time' => 0, 'invalidated_grants' => [d['executions'].values.first['grant']['id']]))
    d['readiness'] << receipt
    e = d['executions'].values.first
    e['grant'] = nil
    e['epoch'] += 1
  end
}
# Zły dokument ma odmowę danych, nigdy NoMethodError walidatora.
rows = []
variants.each do |name, mutate|
  document = JSON.parse(healthy); mutate.call(document)
  bytes = JSON.generate(document); File.binwrite(path, bytes)
  outcome = nil
  begin
    execution_for(context, record, players.first) do |facade|
      select_match(facade, record)
      outcome = facade.current
    end
  rescue Exception => error
    outcome = {exception: error.class.name, message: error.message, backtrace: error.backtrace}
  end
  rows << {name: name, actual: outcome, exact: File.binread(path) == bytes.b}
  File.binwrite(path, healthy)
end
oracle_file('ft2_c08_shapes.json', rows)
rows.each do |r|
  assert(r[:actual][:state] == :blocked && r[:exact], "RED_FT2A_C08_SHAPE: #{r[:name]} wymaga ścisłej odmowy danych")
end
puts 'GREEN C08: typy dokumentu i monotoniczny czas gotowości'
