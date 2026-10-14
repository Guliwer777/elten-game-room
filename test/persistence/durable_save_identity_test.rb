# encoding: UTF-8
require_relative '../support/durable_save_tampering'
include DurableSaveTampering

%w[uuid uploader manifest digest checksum prefix missing duplicate_uuid utf8 nesting].each do |variant|
  scenario("Uzgodnienie odrzuca #{variant} bez upload/close/zmiany intencji") do |root,h,store,service,archive,command|
    operation = lost(command,h,store,service)
    tampered_archive(root,store,service) do |remote,item,text,document|
      archive.validate(JSON.parse(text), game: h.game)
      case variant
      when 'uuid' then item['resource'] = item['resource'].sub(operation['id'], operation['id'][0...-1])
      when 'uploader' then item['uploader'] = 'Bob'
      when 'manifest' then item['meta'] = item['meta'].sub('Alice','Bob')
      when 'digest' then item['data'] = Base64.strict_encode64(Zlib::Deflate.deflate(text.sub('Native','NATIVE')))
      when 'checksum'
        row = JSON.parse(text).merge('checksum'=>'0' * 64)
        replace_bytes(item,document,JSON.generate(row))
      when 'prefix' then document['operations'][0]['values']['prefix']['sha256'] = '0' * 64
      when 'missing' then remote['resources'] = []
      when 'duplicate_uuid' then remote['resources'] << item.merge('id'=>item['id'] + 1)
      when 'utf8' then replace_bytes(item,document,text.b.sub('Native'.b, "\xFFative".b))
      when 'nesting' then replace_bytes(item,document,text.sub('{', '{"excess":' + '[' * 101 + '0' + ']' * 101 + ','))
      end
    end
    before, remote_before = File.binread(store.path), service.state
    error = caught { archive.reconcile(intent: store, id: operation['id'], game: h.game) }
    assert(error.is_a?(IOError), "Przyjęto #{variant} albo zgubiono kontrakt błędu: #{error.inspect}")
    assert(File.binread(store.path) == before && service.state == remote_before, 'Odmowa zmodyfikowała źródła')
    assert(store.fetch(operation['id'])['status'] == 'uncertain' && service.state['uploads'] == 1, 'Odmowa ponowiła/potwierdziła zapis')
    assert(frozen?(h) && !h.core.closed, 'Odmowa zwolniła granicę lub zamknęła stół')
  end
end

scenario('Poprawny UTF-8 pozostaje dokładny w bajtach archiwum i manifestu') do |_root,h,store,service,archive,command|
  h.table['name'] = 'Zażółć gęślą jaźń'
  error = save(command,h,store)
  assert(error.is_a?(Intent::ClosePending), "Nie zapisano poprawnego UTF-8: #{error.inspect}")
  operation = store.list.fetch(0)
  row = archive.reconcile(intent: store, id: operation['id'], game: h.game)
  assert(row['table_name'] == h.table['name'], 'Zmieniono polski tekst')
  assert(operation['id'].match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/), 'Niepełny UUID')
  assert(service.state['uploads'] == 1 && frozen?(h) && !h.core.closed, 'Poprawny odczyt wykonał close/reupload')
end
