require_relative 'client_helpers'
include DuckClientTest

transport = Struct.new(:maximum, :seen) do
  def game_action_limits(table_id)
    seen << table_id
    {'max_stack_entry_bytes' => maximum, 'max_stack_entries' => 4096}
  end
end.new(1536, [])
setup_client('copy_number', transport: transport)
begin
  assert_equal(1536, @client.context_data.fetch('duck_stack_entry_bytes'))
  transport.maximum = 1200
  assert_equal(1200, @client.context_data.fetch('duck_stack_entry_bytes'))
  assert(transport.seen.all? { |id| id == 18 }, 'The client read capabilities of another native table')
  transport.maximum = nil
  assert_equal(nil, @client.context_data.fetch('duck_stack_entry_bytes'))
  assert_equal(1, @game.loads, 'Capability refresh reloaded resources')
  close
  calls = transport.seen.length
  assert_equal({}, @client.context_data)
  assert_equal(calls, transport.seen.length)
ensure
  close
end
report('Duck local native wire limit projection, changing grant and closed lifecycle')
