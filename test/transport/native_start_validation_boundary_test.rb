require_relative '../support/native_live_sessions'
require_relative '../../games/uno'
require 'digest'

base = {'session_id'=>123, 'game'=>'uno', 'options'=>'{}', 'players'=>%w[Alice Bob], 'created_at'=>1}
restored = base.merge('archive_id'=>'saved-123', 'archive_events'=>2, 'event_id_base'=>200,
  'clock_offset'=>-5, 'initial_players'=>%w[Alice Carol], 'controllers'=>{'Bob'=>'bot'})
private_metadata = {'protocol'=>GameRoomLiveSessionStore::PRIVATE_CARDS_DISCOVERY_PROTOCOL,
  'private_cards'=>GameRoomPrivateCards::VERSION}
private_data = base.merge('private_cards'=>GameRoomPrivateCards::VERSION,
  'server_random'=>GameRoomServerRandom::VERSION)
random_metadata = {'protocol'=>GameRoomLiveSessionStore::SERVER_RANDOM_DISCOVERY_PROTOCOL}
checks = []
validate = lambda do |name, data, expected, metadata = {}, sender = 'Alice', actor = 'Alice'|
  packet = {'version'=>2, 'kind'=>'game_started', 'actor'=>actor, 'data'=>data}
  input = Marshal.dump([packet, metadata])
  validator = GameRoomLiveSessionStore::RecordValidator.new(metadata: metadata)
  result = validator.send(:valid_record?, sender, packet, owner: 'Alice')
  assert(result == expected, "#{name}: expected #{expected.inspect}, got #{result.inspect}")
  assert(Marshal.dump([packet, metadata]) == input, "#{name}: validation changed its input")
  checks << [name, result]
end

validate.call('ordinary', base, true)
validate.call('owner aliases', base, true, {}, 'ALICE', 'alice')
validate.call('forged sender', base, false, {}, 'Mallory')
validate.call('forged actor', base, false, {}, 'Alice', 'Bob')
validate.call('invalid sender', base, false, {}, '')
validate.call('invalid actor', base, false, {}, 'Alice', nil)
validate.call('missing random requirement', base, false, random_metadata)
validate.call('native random required', base.merge('server_random'=>GameRoomServerRandom::VERSION), true, random_metadata)
validate.call('unknown random version', base.merge('server_random'=>999), false)
validate.call('ordinary cannot claim private', private_data, false)
validate.call('private native start', private_data, true, private_metadata)
validate.call('private missing flag', base, false, private_metadata)
validate.call('private cannot restore', restored.merge('private_cards'=>GameRoomPrivateCards::VERSION), false, private_metadata)
validate.call('private cannot use bot', private_data.merge('players'=>['Alice', GameRoomParticipants.bot_id(1, 1)]), false, private_metadata)
validate.call('private unsupported game', private_data.merge('game'=>'not-a-game'), false, private_metadata)
validate.call('restored seats and controller', restored, true)
validate.call('new game initial seats', base.merge('initial_players'=>%w[Alice Bob]), false)
validate.call('new game controller', base.merge('controllers'=>{'Bob'=>'bot'}), false)
validate.call('different seat count', restored.merge('initial_players'=>['Alice']), false)
validate.call('duplicate original seats', restored.merge('initial_players'=>%w[Alice alice]), false)
validate.call('foreign controller seat', restored.merge('controllers'=>{'Mallory'=>'bot'}), false)
validate.call('invalid controller kind', restored.merge('controllers'=>{'Bob'=>'unknown'}), false)
validate.call('invalid controller collection', restored.merge('controllers'=>[]), false)
validate.call('valid statistics', base.merge('statistics'=>{'id'=>'01234567-89ab-cdef-0123-456789abcdef', 'mode'=>'humans'}), true)
validate.call('invalid statistics', base.merge('statistics'=>{'id'=>'bad', 'mode'=>'humans'}), false)

%w[archive_events event_id_base clock_offset].each do |field|
  validate.call("orphan #{field}", base.merge(field=>0), false)
  validate.call("missing #{field}", restored.reject { |key, _| key == field }, false)
end
[['session_id', 0], ['created_at', -1], ['options', '[]'], ['options', '{'],
 ['game', ''], ['players', []], ['players', nil], ['players', ['Alice', 'alice']],
 ['players', ['Alice', 'x' * 65]], ['players', (1..9).map { |i| "Player#{i}" }]].each do |field, value|
  validate.call("invalid #{field}=#{value.inspect}", base.merge(field=>value), false)
end
validate.call('eight unique participants', base.merge('players'=>(1..8).map { |i| "Player#{i}" }), true)
validate.call('empty archive ID', restored.merge('archive_id'=>''), false)
validate.call('too long archive ID', restored.merge('archive_id'=>'x' * 65), false)
validate.call('negative archive count', restored.merge('archive_events'=>-1), false)
validate.call('negative event ID base', restored.merge('event_id_base'=>-1), false)
validate.call('fractional clock offset', restored.merge('clock_offset'=>0.5), false)
puts "PASS native start validation: #{checks.size} authority, protocol, archive, controller and identity boundaries; #{Digest::SHA256.hexdigest(JSON.generate(checks))}"
