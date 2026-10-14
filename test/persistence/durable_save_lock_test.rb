# encoding: UTF-8
require 'open3'
require 'rbconfig'
require 'timeout'
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('R1: dwa procesy wspólnego katalogu; odmowa przed freeze bez deadlocku') do |root, h, store, service, archive, command|
  DurableSaveFixture.save_room(root, h)
  worker = File.expand_path('../support/durable_save_lock_process.rb', __dir__)
  Timeout.timeout(30) do
    Open3.popen3(RbConfig.ruby, worker, root, 'A') do |input, output, errors, waiter|
      assert(output.gets.start_with?('locked '), 'A nie osiągnął bariery pod rzeczywistym lockiem')
      raw, err, status = Open3.capture3(RbConfig.ruby, worker, root, 'B')
      File.binwrite(File.join(root, 'save-lock-B-raw.bin'), raw + err)
      assert(status.success?, "B: #{raw} #{err}")
      b = DurableSaveFixture.read(File.join(root, 'save-lock-B.json'))
      assert(b['error'] == Intent::Pending.name && b['unchanged'] && b['uploads'] == 0 && b['empty_intents'],
        'B przeszedł przez freeze/prepare podczas blokady A')
      # Odrzucony proces nie zwalnia blokady A; trzeci obiekt rodzica też odmawia.
      assert(save(command, h, store).is_a?(Intent::Pending) && store.list.empty?, 'B zwolnił blokadę A')
      input.puts('resume'); input.close
      raw = output.read + errors.read
      File.binwrite(File.join(root, 'save-lock-A-raw.bin'), raw)
      assert(waiter.value.success?, "A: #{raw}")
      a = DurableSaveFixture.read(File.join(root, 'save-lock-A.json'))
      assert([a['pid'], b['pid'], Process.pid].uniq.size == 3, 'Nie wykonano dwóch odrębnych procesów')
      assert(a['error'] == Intent::Uncertain.name && a['frozen'] && a['status'] == 'uncertain' && a['uploads'] == 1,
        'A nie zachował ochrony pojedynczego uploadu')
      bytes = File.binread(store.path)
      restored = DurableSaveFixture.load_room(root)
      other = DurableSaveFixture.intent(root)
      command = DurableSaveFixture.use_case(restored, archive)
      before = Marshal.load(Marshal.dump(restored.core.entries))
      looked_up = false
      other.define_singleton_method(:for_source) { |**args| looked_up = true; super(**args) }
      assert(save(command, restored, other).is_a?(Intent::Pending) && looked_up, 'Lock po procesie A nie jest zwolniony')
      assert(File.binread(store.path) == bytes && restored.core.entries == before && service.state['uploads'] == 1,
        'Późniejsza odmowa zmieniła rekord albo receipt')
      puts JSON.generate('processes'=>[a,b], 'parent_pid'=>Process.pid)
    end
  end
end
