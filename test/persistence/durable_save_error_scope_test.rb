# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('R2: best-effort nie połyka nieoczekiwanego błędu programu dziennika') do |_root, h, store, service, _archive, command|
  upload_error = ProgramError.new('Błąd upload')
  journal_error = NoMethodError.new('Nieoczekiwany błąd programu podczas uncertain')
  service.failure = upload_error
  store.define_singleton_method(:uncertain) { |_id| raise journal_error }
  error = save(command, h, store)
  assert(error.equal?(journal_error) && error.cause.equal?(upload_error), 'Rozszerzono rescue do maskowania nieoczekiwanego błędu programu')
  assert(store.list.fetch(0)['status'] == 'attempted' && service.state['uploads'] == 1 && frozen?(h) && !h.core.closed,
    'Błąd best-effort zmienił prawo uploadu lub granicę')
end
