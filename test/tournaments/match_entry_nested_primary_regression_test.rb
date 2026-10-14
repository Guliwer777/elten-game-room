# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/match_entry_screen'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
include GameRoomTest::Assertions
G = GameRoomTournaments
T = TournamentLocalHubTest
results = []
# Natywny Escape pomocy pompuje primary; ensure szczegółów może wykonać lokalny throw.
[:parent, :details].product([false, true], [false, true]).each do |kind, expire, with_cause|
  Dir.mktmpdir('nested-primary-', ENV.fetch('TMPDIR')) do |directory|
    program = TournamentMatchEntryTest.prepare(directory)
    owner = G::LocalTestDialogs::Owner.new(-> { 'RealOwner' }, ->(*) {})
    workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
      user: owner.method(:current), actor: 'Bob', alert: ->(*) {})
    screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
    driver = TournamentNativeDriver.new
    primary = NoMethodError.new('Pierwotny błąd powrotu pomocy')
    primary.set_backtrace(['zagniezdzony_powrot.rb:19'])
    cause = with_cause ? ArgumentError.new('Bezpośrednia przyczyna') : nil
    observed = nil
    reached = 0
    counts = after = nil
    invoke = lambda do |form|
      begin
        begin
          raise IOError, 'Wcześniej obsłużony wyjątek wywołującego'
        rescue IOError
          form.game_room_hotkey_action(1).call
        end
      rescue Exception => error
        observed = error
      end
      after = [SpeechOutput.calls.size, NVDA.calls.size]
    end
    driver.step('My tournaments') do |form|
      T.button(form, 'Check status').press
      kind == :details ? form.accept_button.press : invoke.call(form)
    end
    driver.step('Match details') { |form| invoke.call(form) } if kind == :details
    driver.step('Keyboard shortcuts', [27])
    driver.on_resume = lambda do |form|
      next unless form.fields.first.header == 'Keyboard shortcuts'
      reached += 1
      screen.controller.close if expire
      counts = [SpeechOutput.calls.size, NVDA.calls.size]
      raise primary, cause: cause
    end
    unless expire
      driver.step('Match details', [27]) if kind == :details
      driver.step('My tournaments', [27])
    end
    screen.run
    driver.finish
    windows = driver.forms.filter_map { |form| form.instance_variable_get(:@hub_interaction)&.receiver }.uniq
    state_ok = driver.forms.all? { |form| form.instance_variable_get(:@entry_depth) == 0 } &&
      windows.all? { |window| !window.instance_variable_get(:@busy) && window.instance_variable_get(:@finished) }
    registries = [program, program.class.app_runtime].map { |port| port.managed_resources.size }
    passed = reached == 1 && observed.equal?(primary) && observed.cause.equal?(cause) &&
      observed.backtrace == ['zagniezdzony_powrot.rb:19'] && registries == [0, 0] && state_ok
    passed &&= after == counts if expire
    row = {id: "#{kind}_F1_primary_expire_#{expire}_cause_#{with_cause}", passed: passed,
      identity: observed.equal?(primary), type: observed&.class&.name, cause: observed&.cause&.class&.name,
      backtrace: observed&.backtrace, reached: reached, registries: registries, state_ok: state_ok,
      counts_at_primary: counts, counts_after: after}
    results << row
    puts JSON.generate(row)
  end
end
assert(results.all? { |row| row[:passed] }, 'Zagnieżdżony powrót zgubił primary albo naruszył lifecycle/lease')

# Dodatkowe kontrole tego samego ensure: własny cleanup spod ambient rescue,
# wtórny wyjątek oraz unieważnienie dopiero w before_focus rodzica pomocy.
[[:cleanup_only, false], [:primary_cleanup, false], [:primary_cleanup, true],
 [:primary_abort, false], [:primary_abort, true]].each do |mode, with_cause|
  Dir.mktmpdir('nested-restore-', ENV.fetch('TMPDIR')) do |directory|
    program = TournamentMatchEntryTest.prepare(directory)
    owner = G::LocalTestDialogs::Owner.new(-> { 'RealOwner' }, ->(*) {})
    workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
      user: owner.method(:current), actor: 'Bob', alert: ->(*) {})
    screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
    driver = TournamentNativeDriver.new
    primary = NoMethodError.new('Pierwotny błąd przed odtworzeniem fokusu')
    primary.set_backtrace(['pierwotny.rb:7'])
    cause = with_cause ? ArgumentError.new('Bezpośrednia przyczyna') : nil
    secondary = IOError.new('Błąd przywracania fokusu')
    secondary.set_backtrace(['sprzatanie.rb:9'])
    details = observed = counts = after = nil
    callbacks = 0
    driver.step('My tournaments') do |form|
      T.button(form, 'Check status').press
      form.accept_button.press
    end
    driver.step('Match details') do |form|
      details = form
      begin
        begin; raise IOError, 'Obsłużony wyjątek wywołującego'; rescue IOError
          form.game_room_hotkey_action(1).call
        end
      rescue Exception => error
        observed = error
      end
      after = [SpeechOutput.calls.size, NVDA.calls.size]
    end
    driver.step('Keyboard shortcuts', [27])
    driver.on_resume = lambda do |form|
      next unless form.fields.first.header == 'Keyboard shortcuts'
      details.fields.first.on(:before_focus) do
        callbacks += 1
        window = details.instance_variable_get(:@hub_interaction).receiver
        assert(window.instance_variable_get(:@busy), 'Cleanup opuścił busy przed przywróceniem fokusu')
        details.accept_button.press
        assert(!window.instance_variable_get(:@finished), 'Reentrant Back zamknął aktywne interaction')
        counts = [SpeechOutput.calls.size, NVDA.calls.size]
        if mode == :primary_abort
          screen.controller.close
        else
          raise secondary, cause: nil
        end
      end
      raise primary, cause: cause unless mode == :cleanup_only
    end
    unless mode == :primary_abort
      driver.step('Match details', [27])
      driver.step('My tournaments', [27])
    end
    screen.run
    driver.finish
    expected = mode == :cleanup_only ? secondary : primary
    assert(observed.equal?(expected), "#{mode}: zastąpiono wyjątek")
    assert(observed.cause.equal?(mode == :cleanup_only ? nil : cause), "#{mode}: zmieniono bezpośredni cause")
    assert(observed.backtrace == (mode == :cleanup_only ? ['sprzatanie.rb:9'] : ['pierwotny.rb:7']), "#{mode}: zmieniono backtrace")
    assert(callbacks == 1 && after == counts, "#{mode}: callback powtórzony lub niedozwolona prezentacja")
    assert(driver.forms.all? { |form| form.instance_variable_get(:@entry_depth) == 0 }, "#{mode}: pozostawiono głębokość")
    assert([program, program.class.app_runtime].all? { |port| port.managed_resources.size == 0 }, "#{mode}: pozostawiono zasoby")
    puts "PASS #{mode}, cause=#{with_cause}: tożsamość/backtrace/cause, busy, natywny cleanup"
  end
end

# Zdrowe Details -> F1 -> Escape -> Back -> ponowne wejście: pojedynczy fokus
# i zachowany caret mimo zmiany pola/kursora w prawdziwym resume pomocy.
Dir.mktmpdir('nested-healthy-', ENV.fetch('TMPDIR')) do |directory|
  program = TournamentMatchEntryTest.prepare(directory)
  owner = G::LocalTestDialogs::Owner.new(-> { 'RealOwner' }, ->(*) {})
  workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
    user: owner.method(:current), actor: 'Bob', alert: ->(*) {})
  screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
  driver = TournamentNativeDriver.new
  details = counts = nil
  events = []
  driver.on_resume = lambda do |form|
    next unless form.fields.first.header == 'Keyboard shortcuts'
    details.index = 1
    details.fields.first.index, details.fields.first.check = 0, 0
    details.accept_button.press
    counts = [SpeechOutput.calls.size, NVDA.calls.size]
  end
  2.times do |round|
    driver.step('My tournaments') do |form|
      T.button(form, 'Check status').press if round == 0
      form.accept_button.press
    end
    driver.step('Match details') do |form|
      details = form
      field = form.fields.first
      field.index, field.check = 3, 7
      saved = [form.index, field.text, field.index, field.check]
      window = form.instance_variable_get(:@hub_interaction).receiver
      field.on(:before_focus) { events << [:before, window.instance_variable_get(:@busy)] }
      field.on(:focus) { events << [:focus, window.instance_variable_get(:@busy)] }
      form.game_room_hotkey_action(1).call
      assert([form.index, field.text, field.index, field.check] == saved, 'Zdrowy F1 zgubił pole/tekst/caret')
      assert([SpeechOutput.calls.size - counts[0], NVDA.calls.size - counts[1]] == [1, 1], 'Zdrowy F1 nie ma jednego natywnego odczytu')
      assert(events == [[:before, true], [:focus, true]], 'Zdrowy F1 zmienił kolejność fokusu albo busy')
      assert(!window.instance_variable_get(:@busy) && !window.instance_variable_get(:@finished), 'Zdrowy F1 nie zwolnił interaction')
      events.clear
    end
    driver.step('Keyboard shortcuts', [27])
    driver.step('Match details', [27])
  end
  driver.step('My tournaments', [27])
  screen.run
  driver.finish
  assert(driver.forms.all? { |form| form.instance_variable_get(:@entry_depth) == 0 }, 'Zdrowy powrót pozostawił głębokość')
  assert([program, program.class.app_runtime].all? { |port| port.managed_resources.size == 0 }, 'Zdrowy powrót pozostawił Registry')
  puts 'PASS zdrowe Details/F1/Escape/Back/reentry: caret, pojedynczy fokus, reentrant Back'
end
puts "PASS zagnieżdżone primary: #{results.length} przypadków primary + 5 kontroli cleanup + zdrowy powrót/reentry"
