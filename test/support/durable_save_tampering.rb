# encoding: UTF-8
require_relative 'durable_save_cases'

module DurableSaveTampering
  include DurableSaveCases

  def tampered_archive(root, store, service)
    remote = service.state
    item = remote['resources'].fetch(0)
    text = Zlib::Inflate.inflate(Base64.strict_decode64(item['data']))
    document = DurableSaveFixture.read(store.path)
    yield remote, item, text, document
    DurableSaveFixture.dump(store.path, document)
    DurableSaveFixture.dump(File.join(root,'test-service-private-resources.json'), remote)
  end

  def replace_bytes(item, document, text)
    data = Zlib::Deflate.deflate(text)
    meta = JSON.parse(item['meta']).merge('bytes'=>text.bytesize, 'sha256'=>Digest::SHA256.hexdigest(text))
    item['data'], item['filesize'], item['meta'] = Base64.strict_encode64(data), data.bytesize, JSON.generate(meta)
    values = document['operations'][0]['values']
    values['manifest'], values['sha256'] = item['meta'], meta['sha256']
  end
end
