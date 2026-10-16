# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
context, record, players, path, healthy = c08_bound_fixture
rows = []
[:null_table, :false_metadata, :protocol_echo, :extra_table_field].each do |variant|
  d = JSON.parse(healthy)
  target = d['executions'].values.first['target']
  case variant
  when :null_table then target['readback']['table'] = nil
  when :false_metadata then target['readback']['metadata'] = false
  when :extra_table_field then target['readback']['table']['untrusted'] = 'extra'
  when :protocol_echo
    target['readback']['table']['__discovery_protocol'] = false
    target['readback']['metadata']['protocol'] = false
    target['readback']['discovery']['protocol'] = false
    d['native']['cores'].first['metadata']['protocol'] = false
    d['native']['cores'].first['discovery_metadata']['protocol'] = false
    d['native']['creates'].first['arguments']['metadata']['protocol'] = false
    d['native']['creates'].first['arguments']['discovery_metadata']['protocol'] = false
  end
  bytes = JSON.generate(d); File.binwrite(path, bytes)
  result, mutations = c08_observe do
    begin
      execution_for(context, record, players.first) do |facade|
        select_match(facade, record)
        break facade.current
      end
    rescue Exception => error
      {exception: error.class.name, message: error.message}
    end
  end
  reason = variant == :protocol_echo ? :sandbox_corrupt : :invalid_fields
  expected = {result: {state: :blocked, reason: reason, current: nil, receipt: nil, operation_id: nil}, mutations: [], exact: true}
  rows << {variant: variant, expected: expected, actual: {result: result, mutations: mutations, exact: bytes.b == File.binread(path)}}
  File.binwrite(path, healthy)
end
oracle_file('ft2_c08_native_shapes.json', rows)
rows.each { |r| assert_equal(r[:expected], r[:actual], 'RED_FT2A_C08_NATIVE_SHAPES: zły JSON nie jest błędem programu; echo nie zatwierdza protocol') }
puts 'GREEN C08: pełne kształty natywnego readback oraz ścisły protocol'
