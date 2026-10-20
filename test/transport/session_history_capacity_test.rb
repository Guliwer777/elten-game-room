require_relative '../support/native_live_sessions'

[nil, 32_768].each do |requested|
  broker = NativeLiveSessionsBroker.new
  program = ProgramDouble.new(broker.endpoint('Alice'))
  transport = GameRoomTransport.new(program)
  lobby = LobbyRepository.new(program, transport: transport)
  $game_room_test_user = 'Alice'
  begin
    result = lobby.create_table(name: 'History budget', game: 'test', owner: 'Alice', history_capacity: requested)
    assert(result.created?, 'room was not created')
    assert(broker.cores.values.first.stack_entries == (requested || 4096), 'history request lost in lobby/transport')
    lobby.close_table(result.table)
  ensure
    broker.cores.values.each { |core| core.views.each { |view| view.close unless view.closed? } }
  end
end

broker = NativeLiveSessionsBroker.new
endpoint = broker.endpoint('Alice')
invalid_transport = GameRoomTransport.new(ProgramDouble.new(endpoint))
[nil, '32768', 4095, 32_769].each do |invalid|
  rejected = false
  begin
    invalid_transport.create_room(name: 'Invalid history', game: 'test', owner: 'Alice', game_options: '{}', stack_entries: invalid)
  rescue ArgumentError
    rejected = true
  end
  assert(rejected && broker.cores.empty?, 'invalid history capacity created a session')
end
class << endpoint
  alias_method :create_with_requested_capacity, :create
  def create(**options)
    create_with_requested_capacity(**options.merge(stack_entries: 4096))
  end
end
transport = GameRoomTransport.new(ProgramDouble.new(endpoint))
begin
  rejected = false
  begin
    transport.create_room(name: 'Insufficient history', game: 'test', owner: 'Alice', game_options: '{}', stack_entries: 32_768)
  rescue ArgumentError => error
    rejected = error.message.include?('not granted')
  end
  assert(rejected, 'silently accepted a smaller server history budget')
  assert(broker.cores.values.all?(&:closed), 'rejected room was left open')
ensure
  broker.cores.values.each { |core| core.views.each { |view| view.close unless view.closed? } }
end
puts 'Session history capacity tests passed'
