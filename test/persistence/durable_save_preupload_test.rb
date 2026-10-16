# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('Błąd list przed claim jest definitywny, oddaje własny freeze i nie wysyła') do |_root,h,store,service,_archive,command|
  original = IOError.new('Odmowa odczytu limitu')
  service.define_singleton_method(:list) { |**_options| raise original }
  error = save(command,h,store)
  assert(error.equal?(original), 'Zmieniono pierwotny błąd list')
  assert(service.state['uploads'] == 0 && !frozen?(h) && !h.core.closed, 'Nie oddano własnej granicy bez upload')
  operation = store.list.fetch(0)
  assert(operation['status'] == 'definitive_preupload', 'RED: błąd przed claim pozostawił prepared')
  assert(save(command,h,store).is_a?(Intent::Pending), 'Ponowienie tej samej sesji dostało nowe prawo wysyłki')
  assert(service.state['uploads'] == 0, 'Ponowiono po definitywnej odmowie')
end

scenario('Quota oddaje tylko własną granicę, nie nowszy receipt ani rewanż') do |_root,h,store,service,_archive,command|
  service.quota = 0
  assert(save(command,h,store).is_a?(IOError), 'Nie odrzucono quota')
  assert(!frozen?(h) && store.list.fetch(0)['status'] == 'definitive_preupload', 'Quota nie oddała własnej granicy')
  assert(service.state['uploads'] == 0 && !h.core.closed, 'Quota wysłała lub zamknęła')
end

%w[newer rematch].each do |variant|
  scenario("List failure chroni #{variant}") do |_root,h,store,service,_archive,command|
    replacement = nil
    service.define_singleton_method(:list) do |**_options|
      if variant == 'newer'
        h.transports['Alice'].freeze_game(h.session)
      else
        receipt = h.transports['Alice'].freeze_game(h.session)
        assert(h.transports['Alice'].freeze_game(h.session, frozen: false, expected_boundary: receipt), 'Nie zwolniono własnej nowej granicy')
        assert(h.transports['Alice'].abort_game(h.session), 'Nie zakończono starej partii')
        replacement = h.repositories['Alice'].start_session(table: h.table, game: h.game.id,
          players: %w[Alice Bob], options: h.session['options'], expected_previous_session_id: h.session['__id'])
        h.transports['Alice'].freeze_game(replacement)
      end
      raise IOError, 'Błąd list po nowej granicy'
    end
    failure = save(command,h,store)
    assert(failure.is_a?(IOError), "Nie zachowano błędu list: #{failure.inspect}")
    snapshot = h.repositories['Alice'].snapshot_for(replacement || h.session, force_events: true)
    assert(snapshot.session['__frozen'], 'Rollback zwolnił nowszą granicę/rewanż')
    assert(service.state['uploads'] == 0 && !h.core.closed, 'Wysłano lub zamknięto')
    assert(store.list.fetch(0)['status'] == 'definitive_preupload', 'Brak definitywnego wyniku bez upload')
  end
end
