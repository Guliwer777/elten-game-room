# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases
scenario('Kontrola konta po nieudanym download zatrzaskuje zmianę') do |root,h,store,service,archive,command|
  operation = lost(command,h,store,service)
  original = IOError.new('download przerwany')
  service.define_singleton_method(:download) do |*args, **options|
    Thread.current[:game_room_test_user] = 'Bob'
    raise original
  end
  error = caught { archive.reconcile(intent: store, id: operation['id'], game: h.game) }
  Thread.current[:game_room_test_user] = 'Alice'
  assert(error.equal?(original), 'Zasłonięto błąd download')
  assert(caught { store.list }.is_a?(Intent::ContextChanged), 'Brak kontroli konta po wyjątku download')
  assert(service.state['uploads'] == 1 && frozen?(h), 'Naruszenie niepewności')
end
scenario('Konto sprawdzane po list przed upload także po wyjątku') do |root,h,store,service,archive,command|
  original = IOError.new('list przerwany')
  service.define_singleton_method(:list) do |**options|
    Thread.current[:game_room_test_user] = 'Bob'
    raise original
  end
  error = save(command,h,store)
  Thread.current[:game_room_test_user] = 'Alice'
  assert(error.equal?(original), 'Zasłonięto list')
  assert(caught { store.list }.is_a?(Intent::ContextChanged), 'Brak kontroli po list')
  assert(service.state['uploads'] == 0 && !h.core.closed, 'Wysłano lub zamknięto po zmianie konta')
end
scenario('Lokalny odczyt i zapis sprawdzają konto po I/O') do |root,h,store,service,archive,command|
  lost(command,h,store,service)
  store.singleton_class.prepend(Module.new do
    private
    def read
      result = super
      Thread.current[:game_room_test_user] = 'Bob'
      result
    end
  end)
  error = caught { store.list }
  Thread.current[:game_room_test_user] = 'Alice'
  assert(error.is_a?(Intent::ContextChanged), 'Wydano metadane po zmianie konta podczas read')
  assert(caught { store.list }.is_a?(Intent::ContextChanged), 'Ominięto lokalny zatrzask')
end
