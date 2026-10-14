# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
context, record, players, path, healthy = c08_bound_fixture
rows = []
{executions: 513, operations: 1025, rooms: 513}.each do |kind, count|
  d = JSON.parse(healthy)
  case kind
  when :executions
    seed = d['executions'].values.first
    d['executions'] = count.times.to_h { |i| [i.to_s, seed] }
  when :operations
    seed = d['executions'].values.first['operations']['reserve']
    d['executions'].values.first['operations'] = count.times.to_h { |i| [i.to_s, seed] }
  when :rooms
    d['native']['cores'] *= count
    d['native']['creates'] *= count
  end
  bytes = JSON.generate(d); File.binwrite(path, bytes)
  result, mutations = c08_observe do
    execution_for(context, record, players.first) do |facade|
      select_match(facade, record)
      break facade.current
    end
  end
  rows << {synthetic_counter_only: kind, count: count, actual: result, mutations: mutations, exact: bytes.b == File.binread(path)}
  File.binwrite(path, healthy)
end
oracle_file('ft2_c08_counts.json', rows)
rows.each { |r| assert(r[:actual][:state] == :blocked && r[:actual][:reason] == :sandbox_limit && r[:mutations].empty? && r[:exact], 'RED_FT2A_C08_COUNTS: jawny limit licznika przed walidacją relacyjną') }
puts 'GREEN C08: syntetyczne przekroczenia liczników; nie są naturalnymi planami'
