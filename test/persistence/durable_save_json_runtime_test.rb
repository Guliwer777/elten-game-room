# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

# Symulacja odmiennego parsera: opcja bez object_class nie chroni duplikatów.
# To próba zdolności/fail-closed, nie deklaracja uruchomienia innego Rubiego.
module DurableSaveJsonCapabilities
  def parse(source, **options)
    mode = Thread.current[:durable_save_legacy_json]
    if mode == :unsafe
      options = options.merge(allow_duplicate_key: true, object_class: Hash)
    elsif mode && !options.key?(:object_class)
      options = options.merge(allow_duplicate_key: true)
    end
    super(source, **options)
  end
end
JSON.singleton_class.prepend(DurableSaveJsonCapabilities)

scenario('Ścisły manifest intentu nie ufa samej opcji parsera') do |root,h,store,service,archive,command|
  operation = lost(command,h,store,service)
  remote = service.state
  item = remote['resources'].fetch(0)
  original = item['meta']
  parsed = JSON.parse(original)
  assert(parsed['id'] == operation['id'], 'Nie przygotowano poprawnego manifestu')
  item['meta'] = original.sub('{', '{"\\u0069d":' + JSON.generate(parsed['id']) + ',')
  document = DurableSaveFixture.read(store.path)
  document['operations'][0]['values']['manifest'] = item['meta']
  DurableSaveFixture.dump(store.path, document)
  DurableSaveFixture.dump(File.join(root,'test-service-private-resources.json'), remote)
  before = File.binread(store.path)
  Thread.current[:durable_save_legacy_json] = true
  error = caught { archive.reconcile(intent: store, id: operation['id'], game: h.game) }
  assert(error.is_a?(Intent::Corrupt), "RED: intent przyjął manifest z duplikatem przy innym parserze: #{error.inspect}")
  assert(File.binread(store.path) == before && service.state['uploads'] == 1 && frozen?(h), 'Zmodyfikowano dowód po odmowie')
ensure
  Thread.current[:durable_save_legacy_json] = false
end

scenario('Niebezpieczny runtime odmawia otwarcia i uzgodnienia, bez liberalnego fallbacku') do |root,h,store,service,archive,command|
  operation = lost(command,h,store,service)
  before = File.binread(store.path)
  Thread.current[:durable_save_legacy_json] = :unsafe
  error = caught { DurableSaveFixture.intent(root) }
  assert(error.is_a?(Intent::Error) && error.code == :incompatible_runtime, 'Otwarto dziennik niebezpiecznym parserem')
  error = caught { archive.reconcile(intent: store, id: operation['id'], game: h.game) }
  assert(error.is_a?(GameRoomTournaments::StrictJson::IncompatibleRuntime), 'Uzgodniono pomimo nieskutecznej ochrony JSON')
  assert(File.binread(store.path) == before && service.state['uploads'] == 1 && frozen?(h), 'Niebezpieczny runtime zmienił dane')
ensure
  Thread.current[:durable_save_legacy_json] = false
end
