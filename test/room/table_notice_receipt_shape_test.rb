require 'json'
require 'tmpdir'
require_relative '../support/host_source'
require_relative '../support/ui'
require EltenTestHost.file('src/eapi/resources.rb')
require EltenTestHost.file('src/eapi/program.rb')
require_relative '../support/table_watch'
require_relative '../../lib/table_watch_runtime'

module Session
  def self.name; 'Alice'; end
end

class ReceiptShapeApp
  extend GameRoomTableWatchRuntime
  GAME_REGISTRY = Struct.new(:ids).new(['uno'])

  class << self
    attr_accessor :fixture_runtime
    def server_app_uuid; 'uuid'; end
    def read_json(name, default:); fixture_runtime.read_json(name, default: default); end
    def update_json(name, default:, &block); fixture_runtime.update_json(name, default: default, &block); end

    def reset_receiver
      writer = @table_watch_receipt_writer
      writer&.close
      thread = writer&.instance_variable_get(:@thread)
      raise 'receipt worker did not finish' if thread && !thread.join(3)
      @table_watch_receiver = nil
    end
  end
end

now, ready, cases = 1000.0, true, 0
old_clock = %i[now server_available? synchronized?].to_h { |method| [method, GameRoomClock.method(method)] }
GameRoomClock.define_singleton_method(:now) { raise 'read provisional clock' unless ready; now }
GameRoomClock.define_singleton_method(:server_available?) { true }
GameRoomClock.define_singleton_method(:synchronized?) { ready }
notice = lambda do |session, id = 7|
  WatchNotice.new(id: id, app_uuid: 'uuid', type: GameRoomTableWatch::TYPE, sender: 'Bob',
    metadata: {'format' => 1, 'game' => 'uno', 'table_id' => 12, 'live_session_id' => session,
      'created_at' => 1000, 'expires_at' => 1300})
end

begin
  Dir.mktmpdir('table-notice-receipt-shape-') do |directory|
    runtime = Programs::Runtime.allocate
    runtime.instance_variable_set(:@json_file_monitors_guard, Mutex.new)
    runtime.instance_variable_set(:@json_file_monitors, {})
    runtime.define_singleton_method(:data_path) do |name|
      path = File.expand_path(name, directory)
      raise 'outside owned fixture' unless path.start_with?(directory.tr('\\', '/') + '/')
      FileUtils.mkdir_p(File.dirname(path))
      path
    end
    calls = Hash.new(0)
    %i[read_json write_json update_json].each do |method|
      runtime.define_singleton_method(method) do |*args, **options, &block|
        calls[method] += 1
        super(*args, **options, &block)
      end
    end
    ReceiptShapeApp.fixture_runtime = runtime
    filename = 'table-notice-receipts.json'
    other = {'resolved' => {'other-account-room' => 1400}}
    good = {'seen' => {'seen-room' => {'id' => '7', 'expires' => '1200'}},
      'resolved' => {'resolved-room' => 1250.8}}
    install = lambda do |stored|
      ReceiptShapeApp.reset_receiver
      document = {'alice' => stored, 'carol' => other}
      assert(runtime.write_json(filename, document), 'native fixture write failed')
      assert(runtime.read_json(filename) == document, 'native JSON roundtrip changed receipts')
      [File.binread(runtime.data_path(filename)), calls.dup]
    end
    unchanged = lambda do |before|
      bytes, counts = before
      assert(File.binread(runtime.data_path(filename)) == bytes, 'loading repaired the receipt file')
      assert(calls[:write_json] == counts[:write_json] && calls[:update_json] == counts[:update_json],
        'reading or receiving caused a receipt write')
      assert(calls[:read_json] == counts[:read_json] + 1, 'receipt cache added startup reads or polling')
    end

    # Real Runtime JSON -> actual application adapter -> Receiver, both before
    # and after the native clock is synchronized. Only each bad entry is lost.
    [false, true].each do |cold|
      %w[resolved expires id].each do |field|
        [false, true, [], {}, [1200], {'value' => 1200}].each do |bad|
          stored = JSON.parse(JSON.generate(good))
          if field == 'resolved'
            stored['resolved']['bad-room'] = bad
          else
            stored['seen']['bad-room'] = {'id' => 7, 'expires' => 1200}.merge(field => bad)
          end
          before = install.call(stored)
          ready = !cold
          receiver = ReceiptShapeApp.table_watch_receiver
          assert(!receiver.visible?(notice.call('bad-room')), 'cold clock admitted a notice') if cold
          ready = true
          assert(receiver.equal?(ReceiptShapeApp.table_watch_receiver), 'cached receiver was replaced')
          assert(receiver.visible?(notice.call('bad-room')), "bad #{field} suppressed a new notice")
          assert(receiver.receive(notice.call('bad-room')), 'invalid receipt prevented actual delivery')
          assert(!receiver.receive(notice.call('bad-room')), 'repeated delivery was not deduplicated')
          assert(receiver.visible?(notice.call('seen-room')), 'valid legacy seen ID disappeared')
          assert(!receiver.visible?(notice.call('seen-room', 8)), 'valid legacy seen entry lost deduplication')
          assert(!receiver.visible?(notice.call('resolved-room')), 'valid resolved receipt disappeared')
          unchanged.call(before)
          cases += 1
        end
      end
    end

    # Existing scalar conversion and expiry semantics stay intact, including
    # nil/missing fields, numeric strings and the bounded cold-clock cache.
    scalar_values = [nil, -1, 0, 1000, 1001, 1200.8, '', '1200', '1200.8', '1200tail']
    [false, true].each do |cold|
      scalar_values.each do |scalar|
        stored = {'resolved' => {'scalar-room' => scalar},
          'seen' => {'scalar-seen' => {'id' => scalar, 'expires' => scalar}}}
        before = install.call(stored)
        ready = !cold
        receiver = ReceiptShapeApp.table_watch_receiver
        expected = cold || scalar.to_i > now ? stored : {'resolved' => {}, 'seen' => {}}
        assert(receiver.instance_variable_get(:@resolved) == expected['resolved'], 'resolved scalar changed')
        assert(receiver.instance_variable_get(:@seen) == expected['seen'], 'seen scalar changed')
        ready = true
        assert(receiver.visible?(notice.call('scalar-room')) == (scalar.to_i <= now), 'resolved expiry changed')
        unchanged.call(before)
        cases += 1
      end
    end
    [nil, false, true, 0, 'bad', [], {}].each do |malformed|
      [malformed, {'seen' => malformed, 'resolved' => malformed}].each do |stored|
        before = install.call(stored)
        receiver = ReceiptShapeApp.table_watch_receiver
        assert(receiver.receive(notice.call('new-room')), 'malformed collection blocked normal delivery')
        unchanged.call(before)
        cases += 1
      end
    end

    # The real writer rereads the saved file. An ignored malformed neighbour
    # must not poison a later explicit resolve, and late snapshots still merge.
    before = install.call(good)
    receiver = ReceiptShapeApp.table_watch_receiver
    newer = JSON.parse(JSON.generate(good))
    newer['resolved'].merge!('damaged-room' => false, 'newer-room' => '1450.8', 'resolved-room' => 1550.5)
    assert(runtime.write_json(filename, {'alice' => newer, 'carol' => other}), 'later fixture write failed')
    writes_before = calls[:update_json]
    receiver.resolve('joined-room')
    writer = ReceiptShapeApp.instance_variable_get(:@table_watch_receipt_writer)
    assert(writer.instance_variable_get(:@thread).join(3), 'explicit receipt write stalled')
    assert(writer.instance_variable_get(:@pending).nil? && writer.instance_variable_get(:@failures) == 0,
      'malformed persisted neighbour left a successful join receipt pending')
    assert(calls[:update_json] == writes_before + 1, 'one explicit resolve did not use one native update')
    saved = runtime.read_json(filename)
    assert(saved['carol'] == other, 'receipt save changed another account')
    assert(saved['alice'] == {'resolved' => {'resolved-room' => 1550.5, 'newer-room' => '1450.8', 'joined-room' => 1300.0}},
      'receipt save lost a newer date, changed scalar dates or retained a malformed entry')
    ReceiptShapeApp.reset_receiver
    fresh = ReceiptShapeApp.table_watch_receiver
    assert(!fresh.visible?(notice.call('joined-room')), 'restart lost newly confirmed receipt')
    assert(!fresh.visible?(notice.call('resolved-room')), 'restart lost newer existing receipt')
    cases += 1
  ensure
    ReceiptShapeApp.reset_receiver
  end
ensure
  old_clock.each { |method, implementation| GameRoomClock.define_singleton_method(method, implementation) }
end

puts "PASS #{cases} table receipt native JSON cases: warm/cold startup, scalar compatibility, no autowrite, explicit merge and restart"
