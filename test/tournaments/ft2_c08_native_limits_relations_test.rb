# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
context, record, _players, path, healthy = c08_bound_fixture
variants = {
  stack_entries_false: ->(d) { d['native']['cores'].first['stack_entries'] = false },
  stack_bytes_null: ->(d) { d['native']['cores'].first['stack_entry_bytes'] = nil },
  stack_bytes_string_echo: ->(d) { d['native']['cores'].first['stack_entry_bytes'] = d['native']['creates'].first['arguments']['stack_entry_bytes'] = '16384' },
  stack_bytes_small_echo: ->(d) { d['native']['cores'].first['stack_entry_bytes'] = d['native']['creates'].first['arguments']['stack_entry_bytes'] = 1 },
  participant_metadata: ->(d) { d['native']['creates'].first['arguments']['participant_metadata'] = {'user' => 'Obcy'} }
}
c08_corruption(context, record, path, healthy, variants)
puts 'GREEN C08: natywne argumenty i ograniczenia stosu są ścisłe i relacyjne'
