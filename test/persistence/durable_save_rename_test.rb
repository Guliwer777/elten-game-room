# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

module DurableSaveRenameFailure
  def rename(source, target)
    fault = Thread.current[:durable_save_rename_fault]
    if fault && target == fault[:path]
      record = JSON.parse(File.binread(source)).fetch('operations').last
      if record['status'] == fault[:status]
        Thread.current[:durable_save_rename_fault] = nil
        super if fault[:after]
        raise IOError, 'Kontrolowana awaria rename'
      end
    end
    super
  end
end
File.singleton_class.prepend(DurableSaveRenameFailure)

[['attempted', false], ['attempted', true], ['prepared', true]].each do |status,after|
  scenario("Awaria rename #{status} after=#{after}: bez upload i ślepego retry") do |_root,h,store,service,archive,command|
    Thread.current[:durable_save_rename_fault] = {path: store.path, status: status, after: after}
    error = save(command,h,store)
    assert(error.is_a?(Intent::Error) && error.code == :journal_io_error, "Zmieniono błąd rename: #{error.inspect}")
    assert(service.state['uploads'] == 0 && !h.core.closed, 'Awaria rename pozwoliła wysłać')
    operation = store.list.fetch(0)
    expected = status == 'attempted' && after ? 'attempted' : 'prepared'
    assert(operation['status'] == expected, 'Niezgodny stan utrwalony')
    assert(frozen?(h) == (status == 'attempted'), 'Nieprawidłowy zakres zachowania freeze')
    before = File.binread(store.path)
    2.times do
      assert(save(command,h,store).is_a?(Intent::Pending), 'Retry prepared/attempted udzieliło wysyłki')
      outcome = caught { archive.reconcile(intent: store, id: operation['id'], game: h.game) }
      assert(outcome.is_a?(expected == 'prepared' ? Intent::Pending : Intent::Uncertain), 'Brak zasobu nie zachował niepewności')
    end
    assert(File.binread(store.path) == before && service.state['uploads'] == 0, 'Retry zmieniło dowód lub wysłało')
  ensure
    Thread.current[:durable_save_rename_fault] = nil
  end
end
