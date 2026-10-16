# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

%w[uuid native_room duplicate_uuid duplicate_key owner backend utf8 nesting manifest_duplicate manifest_nesting].each do |variant|
  scenario("Uszkodzony lokalny intent #{variant} odrzucany bez naprawy") do |_root,h,store,service,_archive,command|
    operation = lost(command,h,store,service)
    document = DurableSaveFixture.read(store.path)
    record = document['operations'][0]
    original = File.binread(store.path).force_encoding('UTF-8')
    case variant
    when 'uuid'
      record['id'] = record['values']['archive_id'] = operation['id'][0...-1]
    when 'native_room' then record['values']['source']['native_room'] = '12345678'
    when 'duplicate_uuid' then document['operations'] << record.dup
    when 'owner' then document['owner'] = 'bob'
    when 'backend' then document['backend_identity'] += ':inne'
    when 'manifest_duplicate'
      manifest = record['values']['manifest']
      record['values']['manifest'] = manifest.sub('{', '{"id":' + JSON.generate(operation['id']) + ',')
    when 'manifest_nesting'
      record['values']['manifest'] = record['values']['manifest'].sub('{', '{"deep":' + '[' * 14 + '0' + ']' * 14 + ',')
    end
    raw = case variant
    when 'duplicate_key' then original.sub('"revision":', '"\\u0072evision":1,"revision":')
    when 'utf8' then original.b.sub('alice'.b, "\xFFlice".b)
    when 'nesting' then original.sub('{', '{"deep":' + '[' * 101 + '0' + ']' * 101 + ',')
    else JSON.generate(document)
    end
    File.binwrite(store.path, raw)
    before = File.binread(store.path)
    error = caught { store.fetch(operation['id']) }
    assert(error.is_a?(Intent::Corrupt), "Przyjęto #{variant}: #{error.inspect}")
    assert(File.binread(store.path) == before && service.state['uploads'] == 1 && frozen?(h), 'Odczyt naprawił/ponowił uszkodzony intent')
  end
end
