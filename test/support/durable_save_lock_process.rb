# encoding: UTF-8
# Prawdziwy proces; wspólny dziennik i Resources, bez zmiany reguł transportu.
require_relative 'durable_save_cases'
include DurableSaveCases
root, label = ARGV
DurableSaveFixture.root!(root)
Thread.current[:game_room_test_user] = 'Alice'
h = DurableSaveFixture.load_room(root)
store = DurableSaveFixture.intent(root)
service = DurableSaveFixture::Resources.new(root)
service.intent = store
archive = AccountSavedGames.new(DurableSaveFixture.program, owner: 'Alice', resources: service)
command = DurableSaveFixture.use_case(h, archive)
$stdout.sync = true
if label == 'A'
  store.define_singleton_method(:for_source) do |**args|
    value = super(**args)
    assert(value.nil?, 'Niepusta intencja przed freeze')
    puts "locked #{Process.pid}"
    assert($stdin.gets == "resume\n", 'Brak bariery rodzica')
    value
  end
  service.lost_reply = service.read_failure = true
  error = save(command, h, store)
  DurableSaveFixture.save_room(root, h)
  record = store.list.fetch(0)
  result = {'pid'=>Process.pid, 'error'=>error.class.name, 'frozen'=>frozen?(h), 'status'=>record['status'],
    'id'=>record['id'], 'receipt'=>record.dig('values', 'boundary'), 'uploads'=>service.state['uploads']}
else
  entries = Marshal.load(Marshal.dump(h.core.entries))
  error = save(command, h, store)
  result = {'pid'=>Process.pid, 'error'=>error.class.name, 'unchanged'=>h.core.entries == entries,
    'uploads'=>service.state['uploads'], 'empty_intents'=>store.list.empty?}
end
DurableSaveFixture.dump(File.join(root, "save-lock-#{label}.json"), result)
puts JSON.generate(result)
