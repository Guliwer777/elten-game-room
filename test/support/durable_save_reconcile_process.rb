# encoding: UTF-8
require_relative 'durable_save_fixture'
include DurableSaveFixture
mode, root = ARGV
DurableSaveFixture.root!(root)
if mode == 'A'
  require_relative 'durable_save_process'
  exit! 0 # No ensure, shutdown persistence or object survives into B.
end
raise 'Nieznany etap' unless mode == 'B'
original = read(File.join(root, 'A.json'))
assert(original['pid'] != Process.pid, 'Brak zimnego procesu B')
h = load_room(root)
h.as('Alice') do
  store = intent(root)
  operation = store.fetch(original.fetch('operation').fetch('id'))
  assert(operation == original['operation'], 'Restart zmienił intencję')
  service = Resources.new(root)
  archive = AccountSavedGames.new(program, owner: 'Alice', resources: service)
  command = use_case(h, archive)
  remote = File.binread(File.join(root, 'test-service-private-resources.json'))
  stack = JSON.generate(h.core.entries)
  2.times do
    refusal = nil
    begin
      command.reconcile(intent: store, id: operation['id'], game: h.game)
    rescue GameRoomSavedGameSaveIntent::ClosePending => error
      refusal = error
    end
    assert(refusal && refusal.id == operation['id'] && refusal.code == :close_pending, 'Nie odmówiono niebezpiecznego close')
    current = store.fetch(operation['id'])
    assert(current['status'] == 'readback_confirmed' && current['closed'] == false, 'Nie oddzielono archiwum od zamknięcia')
    assert(!h.core.closed && JSON.generate(h.core.entries) == stack, 'Reconcile zapisał do stołu')
    assert(File.binread(File.join(root, 'test-service-private-resources.json')) == remote, 'Reconcile zmienił zasób')
    assert(service.state['uploads'] == 1, 'Ponowiono upload')
    assert(h.repositories['Alice'].snapshot_for(h.session, force_events: true).session['__frozen'], 'Reconcile oddał freeze')
    assert(h.broker.cores.size == 1, 'Przed close utworzono nowy stół')
  end
  row = archive.reconcile(intent: store, id: operation['id'], game: h.game)
  assert(row['id'] == operation['id'] && GameRoomSavedGameSaveIntent.prefix(row['events']) == operation.dig('values','prefix'), 'Inne UUID/prefiks')
  dump(File.join(root, 'B.json'), {'pid'=>Process.pid, 'upload_count'=>service.state['uploads'],
    'archive_id'=>row['id'], 'status'=>store.fetch(operation['id'])['status'], 'close_pending'=>true,
    'closed'=>h.core.closed, 'fixture_root'=>root})
end
puts 'PASS B: cold read-only reconcile, jeden upload, close_pending, bez restore'
