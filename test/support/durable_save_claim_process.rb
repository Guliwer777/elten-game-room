# encoding: UTF-8
require_relative 'durable_save_cases'
include DurableSaveCases
root, label, id = ARGV
DurableSaveFixture.root!(root)
Thread.current[:game_room_test_user] = 'Alice'
store = DurableSaveFixture.intent(root)
$stdout.sync = true
puts "ready #{Process.pid}"
raise 'Nie odebrano sygnału startu' unless $stdin.gets == "start\n"
result = {'pid'=>Process.pid, 'label'=>label, 'won'=>false}
begin
  claimed = store.claim(id)
  assert(claimed['id'] == id && claimed['status'] == 'attempted', 'Nie przyznano attempted')
  row = DurableSaveFixture.read(File.join(root, 'archive.json'))
  service = DurableSaveFixture::Resources.new(root)
  service.intent = store
  json = JSON.generate(row)
  service.upload("#{AccountSavedGames::PREFIX}#{id}.json.deflate", Zlib::Deflate.deflate(json),
    meta: claimed.dig('values','manifest'), timeout: 15)
  result['won'] = true
rescue Intent::Pending
  result['won'] = false
end
DurableSaveFixture.dump(File.join(root, "claim-#{label}.json"), result)
puts JSON.generate(result)
