# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('Niepewna próba nie zatrzaskuje freeze następnego wywołania tego samego magazynu') do |_root,h,store,service,archive,command|
  first = lost(command,h,store,service)
  service.quota = 0
  second_room = DurableSaveFixture.room
  second = DurableSaveFixture.use_case(second_room, archive)
  error = save(second,second_room,store)
  assert(error.is_a?(IOError), "Nie odrzucono drugiej operacji: #{error.inspect}")
  assert(!frozen?(second_room) && frozen?(h), 'Stan próby wyciekł pomiędzy dwoma wywołaniami')
  assert(store.fetch(first['id'])['status'] == 'uncertain', 'Zmieniono wcześniejszą niepewność')
  assert(store.list.count { |r| r['status'] == 'definitive_preupload' } == 1, 'Brak drugiej definitywnej odmowy')
  third_room = DurableSaveFixture.room
  third = DurableSaveFixture.use_case(third_room, archive)
  assert(caught { third.call(**DurableSaveFixture.arguments(third_room)) }.is_a?(IOError), 'Zwykły zapis nie odmówił quota')
  assert(!frozen?(third_room) && frozen?(h), 'Trwała próba zatrzasnęła zwykły zapis')
  assert(service.state['uploads'] == 1 && !h.core.closed && !second_room.core.closed && !third_room.core.closed, 'Nieprawidłowe upload/close')
end
