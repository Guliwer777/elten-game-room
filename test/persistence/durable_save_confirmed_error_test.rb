# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('R2: potwierdzenie drugim READ nie zasłania obiektu ProgramError i cause') do |root, h, writer, service, archive, command|
  reader = DurableSaveFixture.intent(root)
  cause = IOError.new('Pierwotna przyczyna programu')
  original = caught do
    begin
      raise cause
    rescue IOError
      raise ProgramError, 'Błąd programu po rzeczywistym zapisie upload'
    end
  end
  original_backtrace = original.backtrace.dup
  confirmed, terminal_bytes, confirmed_stack, remote = nil, nil, nil, nil
  service.singleton_class.prepend(Module.new do
    define_method(:upload) do |*args, **options|
      super(*args, **options)
      id = reader.list.fetch(0).fetch('id')
      archive.reconcile(intent: reader, id: id, game: h.game)
      confirmed = reader.fetch(id)
      terminal_bytes = File.binread(reader.path)
      confirmed_stack = Marshal.load(Marshal.dump(h.core.entries))
      remote = state
      raise original, cause: original.cause
    end
  end)
  error = save(command, h, writer)
  assert(confirmed && confirmed['status'] == 'readback_confirmed' && service.state['uploads'] == 1, 'Nie wykonano upload i legalnego readback')
  assert(error.equal?(original) && error.class == ProgramError && error.cause.equal?(cause),
    "R2: zmieniono dokładny ProgramError/cause: #{error.inspect}")
  assert(error.backtrace == original_backtrace, 'Zastąpiono backtrace ProgramError')
  assert(writer.fetch(confirmed['id']) == confirmed && File.binread(writer.path) == terminal_bytes,
    'Pomocnicza niepewność zmieniła terminalny rekord lub jego rewizję')
  assert(frozen?(h) && !h.core.closed && h.core.entries == confirmed_stack && service.state == remote,
    'Obsługa ProgramError wykonała rollback, close lub drugi upload')
  # Best-effort nie maskuje też nieoczekiwanego błędu PROGRAMU samego dziennika.
end
