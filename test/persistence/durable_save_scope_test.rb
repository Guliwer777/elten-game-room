# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('Archiwum zachowuje niezmienny owner mimo mutacji argumentu konstruktora') do |_root,h,store,service,_archive,_command|
  owner = +'Alice'
  archive = AccountSavedGames.new(DurableSaveFixture.program, owner: owner, resources: service)
  owner.replace('Bob')
  command = DurableSaveFixture.use_case(h,archive)
  error = save(command,h,store)
  assert(error.is_a?(Intent::ClosePending), "RED: mutowalny argument podmienił owner archiwum: #{error.inspect}")
  operation = store.list.fetch(0)
  row = archive.reconcile(intent: store, id: operation['id'], game: h.game)
  assert(row['owner'] == 'Alice' && service.state['uploads'] == 1, 'Zapisano dla obcego właściciela')
end

scenario('Owner i backend intentu mają własne niezmienne zakresy bez migracji') do |root,h,_store,service,archive,command|
  owner, backend = +'Alice', +'test-private-resources:v1'
  store = DurableSaveFixture.intent(root, owner: owner, backend: backend)
  service.intent = store
  path = store.path
  owner.replace('Bob')
  backend.replace('inny-backend')
  operation = lost(command,h,store,service)
  assert(store.owner == 'alice' && store.backend_identity == 'test-private-resources:v1' && store.path == path, 'Zmutowano zakres magazynu')
  assert(caught { store.owner.replace('Bob') }.is_a?(FrozenError), 'Owner nie jest niezmienny')
  assert(caught { store.backend_identity.replace('zmiana') }.is_a?(FrozenError), 'Backend nie jest niezmienny')
  original = File.binread(path)
  other_backend = DurableSaveFixture.intent(root, backend: 'inny-backend')
  assert(other_backend.path != path && other_backend.list.empty?, 'Migracja do innego backendu')
  assert(caught { archive.reconcile(intent: other_backend, id: operation['id'], game: h.game) }.is_a?(Intent::Pending), 'Inny backend uzgodnił cudzy zapis')
  h.as('Bob') do
    other_owner = DurableSaveFixture.intent(root, owner: 'Bob')
    assert(other_owner.path != path && other_owner.list.empty?, 'Wydano cudzą intencję')
    assert(caught { archive.reconcile(intent: other_owner, id: operation['id'], game: h.game) }.is_a?(Intent::ContextChanged), 'Archiwum Alice przyjęło owner Bob')
  end
  assert(File.binread(path) == original && service.state['uploads'] == 1, 'Naruszono oryginalny zakres')
end
