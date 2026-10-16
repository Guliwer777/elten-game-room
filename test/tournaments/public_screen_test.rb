# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_public_ui'
require_relative '../../lib/game_room_localization'
GameRoomLocalization.boot(settings: { 'interface_language' => 'en', 'known_languages' => ['en'] })
source = File.expand_path('../../lib/tournaments/public_screen.rb', __dir__)
require source if File.file?(source)
assert(defined?(GameRoomTournaments::PublicScreen), 'Brakuje listy ogłoszeń turniejów')
Form.prepend(TournamentPublicUI::Script)
T = TournamentPublicUI

def screen(snapshot, **options)
  args = T.arguments(snapshot, clock: -> { 150 }, **options).reject { |key, _value| [:publication, :snapshot].include?(key) }
  GameRoomTournaments::PublicScreen.new(**args)
end

row = T.publication
alias_row = row.merge('__id' => 13)
other = T.publication(22, game: 'three_five_eight')
bad = T.publication(44).merge('rules' => '')
initial = T.snapshot([row, alias_row, other, bad], [T.registration(51), T.registration(52, tournament_id: 13),
  T.registration(53, tournament_id: 22, user: 'Obcy')])
before = Marshal.dump(initial)
T.script(lambda do |form|
  list = form.fields.first
  assert(list.options.length == 2, 'Aliasy zduplikowały listę lub wadliwy wpis udaje zaakceptowany')
  assert(list.options.first.include?('Chess') && list.options.first.include?('Próba') && list.options.first.include?('1'), 'Missing title, game or canonical participant count')
  assert(list.instance_variable_get(:@item_keys) == [11, 22], 'Klucze listy nie są ID')
  status = T.field(form, 'Status').text
  assert(status.include?('could not be read'), 'A conflicting announcement lost its warning')
  assert(!status.include?('announcements: 1'), 'The ordinary list exposes internal report counts')
  list.index = 1
  assert(form.accept_button.label == 'View tournament', 'Globalny Enter nie jest podglądem')
  form.accept_button.trigger(:press)
  assert(form.index == 0 && list.index == 1, 'Powrót zgubił pole lub ID')
  form.cancel_button.trigger(:press)
end, lambda do |form|
  assert(form.fields.first.header.include?('Próba 22') && form.accept_button.nil?, 'Podgląd złego ID lub globalny Join')
  form.cancel_button.trigger(:press)
end) { screen(initial).run }
assert(Marshal.dump(initial) == before, 'Lista zmieniła snapshot')
puts 'PASS lista: canonical ID, aliasy, obcy skład, diagnostyki, Enter tylko podgląd'

changed = T.snapshot([row, other.merge('title' => 'Zmieniona etykieta')])
reversed = GameRoomTournaments::Publication::Data.freeze_tree(changed.merge('announcements' => changed['announcements'].reverse))
loads = [initial, reversed, nil, T.snapshot([])]
T.script(lambda do |form|
  list = form.fields.first
  list.index = 1
  form.index = 3
  T.button(form, 'Refresh').trigger(:press)
  assert(list.index == 0 && list.options.first.start_with?('Zmieniona etykieta'), 'Refresh zgubił ID przy zmianie kolejności i etykiet')
  labels = list.options.dup
  T.button(form, 'Refresh').trigger(:press)
  assert(list.index == 0 && list.options == labels && form.index == 3, 'nil odczytu wyczyścił dane lub fokus')
  T.button(form, 'Refresh').trigger(:press)
  assert(list.options.empty?, 'Poprawny pusty snapshot nie wyczyścił listy')
  form.accept_button.trigger(:press)
  form.cancel_button.trigger(:press)
end) { screen(initial, load: -> { loads.shift }).run }
assert(loads.empty?, 'Nie wykonano wszystkich odczytów')
T.script { screen(initial, load: -> { nil }).run }
puts 'PASS refresh: odwrócenie, zmiana etykiety, nil zachowuje ostatni snapshot, pusta lista i początkowy nil'

calls = 0
instance = nil
T.script(lambda do |form|
  form.accept_button.trigger(:press)
  form.cancel_button.trigger(:press)
end, ->(form) { form.cancel_button.trigger(:press) }) do
  instance = screen(initial, load: lambda do
    calls += 1
    instance.run
    initial
  end)
  instance.run
end
assert(calls == 1, 'Ponowne wejście w początkowy load powieliło listę')
puts 'PASS reentry początkowego load nie zamyka i nie powiela listy'

rows=(1..8).map{|id|T.publication(id,**{'participant_limit'=>2})}
rows[0]=rows[0].merge('registration_closes_at'=>140)
rows[3]=rows[3].merge('registration_opens_at'=>160)
rows[7]=rows[7].merge('__insertion_user'=>T::ACTOR,'registration_opens_at'=>160)
members=[T.registration(101,tournament_id:2),T.registration(102,tournament_id:7,user:T::ACTOR.upcase),
  T.registration(103,tournament_id:5,user:'Alpha'),T.registration(104,tournament_id:5,user:'Beta')]
ordered=T.snapshot(rows,members)
loads=0
T.script(lambda do |form|
  list=form.fields.first
  assert_equal([2,7,3,6,1,4,5,8],list.instance_variable_get(:@item_keys))
  assert_equal(1,loads,'Sorting performed additional server reads')
  filter=T.field(form,'Show tournaments')
  filter.index=1
  filter.trigger(:move)
  assert_equal([2,7,8],list.instance_variable_get(:@item_keys),'My filter lost an organizer or changed its publication order')
  filter.index=0
  filter.trigger(:move)
  assert_equal([2,7,3,6,1,4,5,8],list.instance_variable_get(:@item_keys))
  form.cancel_button.trigger(:press)
end) {screen(ordered,clock:-> {150},load:-> {loads+=1;ordered}).run}
puts 'PASS current ordering: membership first, eligible open places next, full/closed/future last; stable groups and organizer distinction'

now=150
expiring=T.snapshot
expiring=expiring.merge('announcements'=>expiring['announcements'].map{|item|item.merge('expires_at'=>151)})
remaining=[expiring,T.snapshot([])]
instance=nil
T.script(lambda do |form|
  now=151
  instance.instance_variable_set(:@lifecycle_dirty,true)
  form.instance_variable_get(:@lifecycle_dispatch).call
  assert_equal([],form.fields.first.options,'The expiry wakeup did not load a fresh directory')
  assert(remaining.empty?,'Expiry did not request one refresh')
  form.instance_variable_get(:@lifecycle_dispatch).call
  assert(remaining.empty?,'Expiry started a polling loop')
  form.cancel_button.trigger(:press)
end) do
  instance=screen(expiring,clock:-> {now},load:-> {remaining.shift || raise('Unexpected additional directory read')})
  instance.run
end
puts 'PASS expiry callback: fresh directory, removed row, no periodic refresh'
