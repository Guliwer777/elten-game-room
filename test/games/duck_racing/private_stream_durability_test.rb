require_relative '../../support/duck_private_round'
require_relative '../../support/hidden_submission_files'
require_relative '../../../games/duck_racing_support/wire_budget'

include DuckPrivateRoundTest
protocol = PRIVATE_ROUND
codec = GameRoomDuckRacing::PrivateTraceStream

class DuckCacheSecondWriteFailure < HiddenSubmissions::MemoryStorage
  def initialize; super; @calls = 0; end
  def update(&block)
    @calls += 1
    raise HiddenSubmissions::StorageError, 'wire cache write failed' if @calls == 2
    super(&block)
  end
end

state, trace = private_state(commit_deadline_ms: nil), input_trace('word', count: 350, kind: 'answer')
trace['actions'].each_with_index { |entry, index| entry['input']['value'] += " #{index}-#{index * 731}" }
storage = HiddenSubmissions::MemoryStorage.new
vault = HiddenSubmissions::Vault.new(storage)
before = Marshal.dump(storage.read)
assert_raises(protocol::CapacityError) { prepare_private(state, 0, trace, vault: vault, available_records: 0) }
assert_equal(before, Marshal.dump(storage.read), 'Failed preflight created local entries')
assert_raises(protocol::CapacityError) do
  prepare_private(state, 0, input_trace('x' * codec::MAX_EXPANDED_BYTES, kind: 'answer'), vault: vault)
end
assert_equal(before, Marshal.dump(storage.read))
fault = DuckCacheSecondWriteFailure.new
assert_raises(HiddenSubmissions::StorageError) do
  prepare_private(state, 0, trace, vault: HiddenSubmissions::Vault.new(fault))
end
assert_equal({}, fault.read['entries'], 'Failed new cache preparation retained its partial original entry')
assert_equal({}, state[:commitments])

Dir.mktmpdir('duck-wire-cache-') do |directory|
  program = HiddenSubmissionFiles.new(directory)
  vault = HiddenSubmissions::Vault.new(program.storage)
  prepared = prepare_private(state, 0, trace, vault: vault)
  assert(prepared.reveal_pages.length > 1, 'Recovery fixture must retain an unaccepted suffix')
  assert_equal(2, program.storage.read['entries'].length)
  previous = Marshal.dump(program.storage.read)
  repeated = prepare_private(state, 0, trace, vault: vault, nonce: 'f' * 64)
  assert_equal(prepared.envelope, repeated.envelope)
  assert_equal(prepared.reveal_pages, repeated.reveal_pages)
  assert_equal(previous, Marshal.dump(program.storage.read), 'Identical retry rewrote the durable cache')
  assert_raises(protocol::InvalidSubmission) { prepare_private(state, 0, input_trace('other'), vault: vault) }
  assert_equal(previous, Marshal.dump(program.storage.read), 'Changed attempt overwrote a possibly accepted original')

  assert(commit_private(state, prepared, 0))
  assert(protocol.forfeit(state, seat: 1, reason: :fixture))
  assert(protocol.close_commits(state, now_ms: 2_000))
  assert(protocol.accept_reveal_page(state, seat: 0, page: prepared.reveal_pages.first, now_ms: 2_001))
  # Simulate another zlib implementation/version by making all fresh whole-
  # stream encoding fail. Restart recovery must use the exact cached bytes.
  original = codec.method(:encode)
  codec.define_singleton_method(:encode) { |_envelope| raise 'Unexpected recompression after restart' }
  begin
    fresh = HiddenSubmissions::Vault.new(HiddenSubmissionFiles.new(directory).storage)
    recovered = protocol.recover(state, seat: 0, user: 'account-0', vault: fresh)
    assert_equal(prepared.reveal_pages, recovered.reveal_pages)
    assert_equal(previous, Marshal.dump(program.storage.read))
    accepted = Marshal.dump(state)
    wire_id = "duck-wire-v2:#{prepared.envelope.commitment}"
    assert(fresh.discard(session_id: state[:session_id], round_id: wire_id, user: 'account-0'))
    assert_raises(protocol::CapacityError) do
      protocol.recover_next_reveal_page(state, seat: 0, user: 'account-0', vault: fresh)
    end
    assert_equal(accepted, Marshal.dump(state), 'Missing cache converted the accepted prefix to a loss')
    assert_equal({}, state[:reveals])
  ensure
    codec.define_singleton_method(:encode, original)
  end
  assert(protocol.cancel(state, reason: 'technical'))
  assert(protocol.discard_local(state, seat: 0, user: 'account-0', vault: fresh))
  assert_equal({}, program.storage.read['entries'])
  assert_equal(nil, protocol.recover(state, seat: 0, user: 'account-0', vault: fresh))
  assert_equal({}, program.storage.read['entries'], 'Cancelled recovery resurrected its cache')
end

# Missing auxiliary bytes are safe to recreate only before any page has been
# accepted, using a verified original envelope with its unchanged nonce/hash.
state = private_state(commit_deadline_ms: nil)
storage = HiddenSubmissions::MemoryStorage.new
vault = HiddenSubmissions::Vault.new(storage)
prepared = prepare_private(state, 0, trace, vault: vault)
assert(commit_private(state, prepared, 0))
wire_id = "duck-wire-v2:#{prepared.envelope.commitment}"
assert(vault.discard(session_id: state[:session_id], round_id: wire_id, user: 'account-0'))
recovered = protocol.recover(state, seat: 0, user: 'account-0', vault: vault)
assert_equal(prepared.envelope, recovered.envelope)
assert_equal(prepared.reveal_pages, recovered.reveal_pages)
assert_equal(2, storage.read['entries'].length)

# Even a self-consistent auxiliary cache cannot substitute another payload.
original = storage.read
storage.update do |root|
  wire = root['entries'].values.find { |entry| entry['round_id'].start_with?('duck-wire-v2:') }
  compact = JSON.parse(Zlib::Inflate.inflate(Base64.strict_decode64(wire['payload']['data'])))
  compact['nonce'] = 'f' * 64
  data = JSON.generate(compact)
  wire['payload']['data'] = Base64.strict_encode64(Zlib::Deflate.deflate(data))
  wire['payload']['unpacked_bytes'] = data.bytesize
  wire['commitment'], = HiddenSubmissions::Commitment.create(wire['payload'], nonce: wire['nonce'])
end
assert_equal(nil, protocol.recover(state, seat: 0, user: 'account-0', vault: vault))
storage.update { |root| root.replace(original) }
assert(protocol.cancel(state, reason: 'technical'))
assert(protocol.discard_local(state, seat: 0, user: 'account-0', vault: vault))
assert_equal({}, storage.read['entries'])

# A blocked cleanup keeps the canonical lookup, then a later normal retry
# removes both entries. It cannot revive a cancelled attempt in between.
Dir.mktmpdir('duck-wire-cleanup-') do |directory|
  state = private_state
  program = HiddenSubmissionFiles.new(directory)
  vault = HiddenSubmissions::Vault.new(program.storage)
  prepare_private(state, 0, trace, vault: vault)
  protocol.cancel(state, reason: 'technical')
  before = program.storage.read
  program.blocked = [HiddenSubmissions::ProgramStorage::DEFAULT_PATH,
    HiddenSubmissions::ProgramStorage::DEFAULT_PATH + '.recovery.json']
  assert_equal(false, protocol.discard_local(state, seat: 0, user: 'account-0', vault: vault))
  assert_equal(before, program.storage.read)
  assert_equal(nil, protocol.recover(state, seat: 0, user: 'account-0', vault: vault))
  program.blocked.clear
  program.retry_now
  assert(protocol.discard_local(state, seat: 0, user: 'account-0', vault: vault))
  assert_equal({}, program.storage.read['entries'])
end

puts 'PASS Duck compressed durability: exact cached bytes after restart, immutable retry, missing/corrupt cache, no partial commit, scoped cleanup and no resurrection'
