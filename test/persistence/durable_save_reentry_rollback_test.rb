# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

%w[validation quota].each do |stage|
  scenario("R1: reentry podczas #{stage}; własny rollback przed uploadem") do |root, h, store, service, archive, command|
    other = DurableSaveFixture.intent(root)
    rejected, snapshots = [], []
    hook = lambda do
      2.times do
        before = Marshal.load(Marshal.dump(h.core.entries))
        rejected << save(command, h, other)
        snapshots << (h.core.entries == before)
      end
    end
    original = ArgumentError.new('Walidacja archiwum przed prepare')
    if stage == 'validation'
      archive.define_singleton_method(:validate) do |row, game:|
        super(row, game: game)
        hook.call
        raise original
      end
    else
      service.define_singleton_method(:max_private_resources_bytes_per_user) { hook.call; 0 }
    end
    error = save(command, h, store)
    assert(stage == 'validation' ? error.equal?(original) : error.is_a?(IOError), "Zmieniono błąd #{stage}: #{error.inspect}")
    assert(rejected.size == 2 && rejected.all? { |e| e.is_a?(Intent::Pending) } && snapshots.all?, 'Reentry zmieniło granicę aktywnej próby')
    assert(service.state['uploads'] == 0 && !frozen?(h) && !h.core.closed, 'Brak własnego rollbacku bez wysyłki')
    boundaries = h.core.entries.select { |entry| entry.dig('packet', 'kind') == 'game_boundary' }
    assert(boundaries.map { |entry| entry.dig('packet', 'data', 'frozen') } == [true, false], 'Zwolniono coś innego niż własny receipt')
    if stage == 'validation'
      assert(store.list.empty?, 'Walidacja dotarła do prepare')
      archive.singleton_class.send(:remove_method, :validate)
      next_error = save(command, h, other)
      assert(next_error.is_a?(Intent::ClosePending) && service.state['uploads'] == 1 && frozen?(h), 'Blokada nie została zwolniona po błędzie walidacji')
    else
      assert(store.list.fetch(0)['status'] == 'definitive_preupload', 'Quota nie utrwaliła definitywnej odmowy')
      # Osobny obiekt musi dostać lock (Pending pochodzi teraz z trwałego precheck).
      looked_up = false
      other.define_singleton_method(:for_source) { |**args| looked_up = true; super(**args) }
      assert(save(command, h, other).is_a?(Intent::Pending) && looked_up, 'Lock pozostał zajęty po rollbacku quota')
    end
  end
end
