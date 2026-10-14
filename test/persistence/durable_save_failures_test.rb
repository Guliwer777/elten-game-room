# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases
scenario('ProgramError po zapisie zachowuje obiekt/cause, attempted i freeze') do |root,h,store,service,archive,command|
  cause = IOError.new('pierwotna przyczyna')
  original = caught { begin; raise cause; rescue IOError; raise ProgramError, 'błąd programu'; end }
  service.failure = original
  error = save(command,h,store)
  assert(error.equal?(original) && error.cause.equal?(cause), "Przebrano błąd programu: #{error.inspect}")
  assert(service.state['uploads'] == 1 && frozen?(h) && !h.core.closed, 'Naruszono niepewny zapis')
  assert(%w[attempted uncertain].include?(store.list.fetch(0)['status']), 'Błąd programu potwierdzono automatycznie')
end
scenario('Zmiana konta po błędzie I/O zatrzaskuje się bez zasłonięcia ProgramError') do |root,h,store,service,archive,command|
  original = ProgramError.new('awaria i zmiana konta')
  service.failure = original
  service.singleton_class.prepend(Module.new do
    def upload(...)
      super
    ensure
      Thread.current[:game_room_test_user] = 'Bob'
    end
  end)
  error = save(command,h,store)
  Thread.current[:game_room_test_user] = 'Alice'
  assert(error.equal?(original), "Zmiana konta zasłoniła ProgramError: #{error.inspect}")
  assert(caught { store.list }.is_a?(Intent::ContextChanged), 'Powrót konta odblokował zatrzaśniętą operację')
  assert(service.state['uploads'] == 1 && frozen?(h) && !h.core.closed, 'Zmieniono niepewny zapis')
end
