require_relative '../../lib/hidden_submissions'
require 'tmpdir'
require_relative '../support/hidden_submission_files'

def assert(value, message)
  raise message unless value
end

class CleanupGameProbe
  include HiddenSubmissions::Cleanup
end

Dir.mktmpdir('confirmed-answer-cleanup-') do |directory|
  files = HiddenSubmissionFiles.new(directory)
  disk = files.storage
  vault = HiddenSubmissions::Vault.new(disk)
  session = 71
  prepare = ->(round, user, payload, target = session) do
    vault.prepare(session_id: target, round_id: round, user: user, payload: payload)
  end
  own = prepare.call('round-1', 'Alice', {'answer' => 1})
  other = prepare.call('round-1', 'Bob', {'answer' => 2})
  foreign = prepare.call('round-1', 'Alice', {'answer' => 3}, session + 1)
  future = prepare.call('round-2', 'Alice', {'answer' => 4})
  stale = prepare.call('round-3', 'Alice', {'answer' => 5})
  newer = prepare.call('round-3', 'Alice', {'answer' => 6})
  state = {}
  HiddenSubmissions::Cleanup.start(state, '__id' => session)
  HiddenSubmissions::Cleanup.confirm(state, 'round-1', 'Alice' => own.commitment, 'Bob' => other.commitment)
  HiddenSubmissions::Cleanup.confirm(state, 'round-3', 'Alice' => stale.commitment)
  replay = Struct.new(:state).new(state)
  game = CleanupGameProbe.new
  cleanup = ->(id, actors) { game.cleanup_session_answers(replay, session_id: id, actors: actors, hidden_submissions: vault) }
  before = files.storage.read
  cleanup.call(session + 1, ['Alice'])
  assert(before == files.storage.read, 'A different session authorized deletion')
  cleanup.call(session, ['Watcher'])
  assert(before == files.storage.read, 'An observer authorized another account cleanup')

  # A failed transaction retains both snapshots and is retried by a later
  # ordinary worker invocation, not by a network timer or a UI callback.
  main = HiddenSubmissions::ProgramStorage::DEFAULT_PATH
  files.blocked = [main, main + '.recovery.json']
  cleanup.call(session, ['ALICE'])
  assert(before == files.storage.read, 'Failed cleanup destroyed durable answers')
  files.blocked = []
  files.retry_now
  cleanup.call(session, ['ALICE'])
  cold = HiddenSubmissions::Vault.new(HiddenSubmissionFiles.new(directory).storage)
  assert(cold.reveal(session_id: session, round_id: 'round-1', user: 'Alice').nil?, 'Confirmed answer survived cold reopen')
  [other, foreign, future, newer].each do |envelope|
    found = cold.reveal(session_id: envelope.session_id, round_id: envelope.round_id, user: envelope.user)
    assert(found&.commitment == envelope.commitment, 'Cleanup erased an unrelated or newer answer')
  end
  assert(cold.reveal(session_id: session, round_id: 'round-3', user: 'Alice', commitment: stale.commitment),
    'A newer uncertain answer lost its older retry version')
  HiddenSubmissions::Cleanup.confirm(state, 'round-3', 'Alice' => newer.commitment)
  cleanup.call(session, ['Alice'])
  assert(cold.reveal(session_id: session, round_id: 'round-3', user: 'Alice').nil?, 'The subsequently confirmed version was not removed')

  # Successful reconciliation is cached only for the same vault and receipts.
  disk.define_singleton_method(:update) { |&| raise 'Repeated clean replay touched storage' }
  cleanup.call(session, ['Alice'])
  fresh = CleanupGameProbe.new
  fresh.cleanup_session_answers(replay, session_id: session, actors: ['Bob'], hidden_submissions: cold)
  assert(cold.reveal(session_id: session, round_id: 'round-1', user: 'Bob').nil?, 'A recreated worker lost accepted receipts')
end

# Change the current envelope at the storage transaction boundary. A separate
# read-then-delete implementation would lose this unacknowledged replacement.
storage = HiddenSubmissions::MemoryStorage.new
vault = HiddenSubmissions::Vault.new(storage)
old = vault.prepare(session_id: 8, round_id: 'r', user: 'Alice', payload: {'answer' => 1})
replacement = HiddenSubmissions::Vault.new(HiddenSubmissions::MemoryStorage.new)
newer = replacement.prepare(session_id: 8, round_id: 'r', user: 'Alice', payload: {'answer' => 2})
replacement_data = {'session_id' => 8, 'round_id' => 'r', 'user' => 'Alice', 'payload' => newer.payload,
  'nonce' => newer.nonce, 'commitment' => newer.commitment, 'versions' => {}}
update = storage.method(:update)
storage.define_singleton_method(:update) do |&block|
  update.call do |root|
    key = root['entries'].keys.first
    root['entries'][key] = replacement_data
    block.call(root)
  end
end
assert(!vault.discard_confirmed(session_id: 8, receipts: [['r', 'Alice', old.commitment]]), 'A stale receipt was accepted')
assert(vault.reveal(session_id: 8, round_id: 'r', user: 'Alice').commitment == newer.commitment,
  'Atomic cleanup erased a concurrently replaced envelope')
puts 'PASS confirmed answer cleanup: real files, account/session scopes, retry versions, failure recovery, cold reopen and atomic replacement'
