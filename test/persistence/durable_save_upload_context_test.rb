# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('Guard upload sprawdza konto także przy przerwaniu spoza StandardError') do |_root,h,store,service,_archive,command|
  interrupted = Interrupt.new('Przerwanie upload')
  service.singleton_class.prepend(Module.new do
    define_method(:upload) do |*args, **options|
      super(*args, **options)
      Thread.current[:game_room_test_user] = 'Bob'
      raise interrupted
    end
  end)
  error = begin
    command.call(**DurableSaveFixture.arguments(h), intent: store)
    nil
  rescue Interrupt => caught_error
    caught_error
  end
  Thread.current[:game_room_test_user] = 'Alice'
  assert(error.equal?(interrupted), 'Zmieniono przerwanie upload')
  assert(caught { store.list }.is_a?(Intent::ContextChanged), 'RED: upload nie zatrzasnął zmiany konta w ensure')
  assert(service.state['uploads'] == 1 && frozen?(h) && !h.core.closed, 'Naruszono niepewną wysyłkę')
end

scenario('Normalny powrót upload po zmianie konta nie przechodzi do odczytu ani confirm') do |_root,h,store,service,_archive,command|
  listed = 0
  service.singleton_class.prepend(Module.new do
    define_method(:list) do |**options|
      listed += 1
      super(**options)
    end
    def upload(...)
      result = super
      Thread.current[:game_room_test_user] = 'Bob'
      result
    end
  end)
  error = save(command,h,store)
  Thread.current[:game_room_test_user] = 'Alice'
  assert(error.is_a?(Intent::ContextChanged), 'Upload zignorował nowe konto')
  assert(listed == 1, 'Wykonano list po zmianie konta w upload')
  assert(caught { store.list }.is_a?(Intent::ContextChanged), 'Powrót właściciela wyłączył guard')
  data = DurableSaveFixture.read(store.path)
  assert(data['operations'][0]['status'] == 'attempted', 'Potwierdzono operację pod innym kontem')
  assert(service.state['uploads'] == 1 && frozen?(h) && !h.core.closed, 'Normalny powrót zwolnił niepewną granicę')
end
