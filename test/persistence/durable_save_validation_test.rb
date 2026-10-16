# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases
scenario('Zgodny digest nie zezwala na duplikat klucza w poprawnym archiwum JSON') do |root,h,store,service,archive,command|
  operation = lost(command,h,store,service)
  remote = service.state
  item = remote['resources'].fetch(0)
  json = Zlib::Inflate.inflate(Base64.strict_decode64(item['data']))
  # The original is a valid, fully validated archive, not an incomplete schema.
  archive.validate(JSON.parse(json), game: h.game)
  json = json.sub('{', '{"format":1,')
  data = Zlib::Deflate.deflate(json)
  meta = JSON.parse(item['meta']).merge('bytes'=>json.bytesize, 'sha256'=>Digest::SHA256.hexdigest(json))
  item['meta'], item['data'], item['filesize'] = JSON.generate(meta), Base64.strict_encode64(data), data.bytesize
  local = DurableSaveFixture.read(store.path)
  local['operations'][0]['values']['sha256'] = meta['sha256']
  local['operations'][0]['values']['manifest'] = item['meta']
  DurableSaveFixture.dump(store.path, local)
  DurableSaveFixture.dump(File.join(root,'test-service-private-resources.json'),remote)
  assert(store.list.length == 1, 'Błędne przygotowanie metadanych')
  error = caught { archive.reconcile(intent: store, id: operation['id'], game: h.game) }
  assert(error.is_a?(IOError), 'Przyjęto duplikat poprawnego JSON mimo zgodnego hasha')
  assert(store.fetch(operation['id'])['status'] == 'uncertain' && service.state['uploads'] == 1, 'Naruszono niepewność')
end
