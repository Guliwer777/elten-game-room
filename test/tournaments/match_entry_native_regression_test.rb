# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/match_entry_screen'
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})
include GameRoomTest::Assertions
G = GameRoomTournaments
T = TournamentLocalHubTest
class EntryRegressionDriver < TournamentNativeDriver
  attr_reader :overrun
  def tick(form)
    if form.is_a?(GameRoomUI::Form) && form.instance_variable_get(:@wait) == true && steps.empty?
      @overrun = true
      form.resume_for_refresh
    end
    super
  end
end
modes = ARGV.empty? ? %w[selection parent_tab details_tab before_focus parent_help details_help parent_direct details_direct details_help_healthy finish_exception] : ARGV
modes.each do |mode|
  Dir.mktmpdir('entry-regression-', ENV.fetch('TMPDIR')) do |directory|
    program = TournamentMatchEntryTest.prepare(directory)
    account = 'RealOwner'
    owner = G::LocalTestDialogs::Owner.new(-> { account }, ->(_message) {})
    workspace = G::LocalWorkspace.new(program: program, registry: GameRoomGames::CATALOG,
      user: owner.method(:current), actor: 'Bob', alert: ->(_message) {})
    screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
    driver = EntryRegressionDriver.new
    counts = nil
    primary = nil
    if mode == 'finish_exception'
      primary = NoMethodError.new('Pierwotny błąd close podczas Back')
      primary.set_backtrace(['zamkniecie.rb:19'])
      release = program.method(:release)
      program.define_singleton_method(:release) { |resource| release.call(resource); raise primary, cause: nil }
      driver.on_resume = ->(form) { form.fields.first.focus }
    end
    driver.step('My tournaments') do |form|
      T.button(form, 'Check status').press
      if mode == 'selection'
        previous = screen.controller.view
        matches = T.field(form, 'My matches')
        matches.index = 2
        match_id = previous[:matches][matches.index]['match_id']
        tournaments = T.field(form, 'My tournaments')
        workspace.define_singleton_method(:entry_load) { |**_| nil }
        tournaments.index = 1
        form.index = 0
        focus_count = 0
        tournaments.on(:focus) { focus_count += 1 }
        tournaments.trigger(:move)
        assert(screen.controller.view.equal?(previous), 'Model utracił poprzedni widok')
        assert(previous[:tournaments][tournaments.index]['__id'] == previous[:selected_id], 'Kursor turnieju nie odpowiada zachowanemu widokowi')
        assert(previous[:matches][matches.index]['match_id'] == match_id, 'Utracono wybrany mecz')
        assert(focus_count == 1, 'Powrót nie ma dokładnie jednego fokusu')
        form.accept_button.press
      elsif mode == 'before_focus'
        list = T.field(form, 'My matches')
        form.index = form.fields.index(list)
        list.on(:before_focus) do
          screen.controller.close
          counts = [SpeechOutput.calls.size, NVDA.calls.size]
        end
        form.focus
      elsif mode.start_with?('details_')
        form.accept_button.press
      elsif mode == 'parent_help'
        form.show_game_room_help
      end
    end
    if mode == 'details_help'
      driver.step('Match details') { |form| form.show_game_room_help }
    end
    if mode.end_with?('_tab') || mode.end_with?('_help')
      header = mode.end_with?('_help') ? 'Keyboard shortcuts' : (mode == 'parent_tab' ? 'My tournaments' : 'Match details')
      driver.step(header, [9]) do |_form|
        account = 'ObceKonto'
        assert(!screen.controller.context.current?(screen.controller.context.capture), 'Nie osiągnięto unieważnienia')
        counts = [SpeechOutput.calls.size, NVDA.calls.size]
      end
    end
    if mode.end_with?('_direct')
      driver.step(mode == 'parent_direct' ? 'My tournaments' : 'Match details') do |form|
        screen.controller.close
        counts = [SpeechOutput.calls.size, NVDA.calls.size]
        form.fields.first.focus
      end
    end
    if mode == 'details_help_healthy'
      returned = nil
      driver.on_resume = lambda do |form|
        returned = [SpeechOutput.calls.size, NVDA.calls.size] if form.fields.first.header == 'Keyboard shortcuts'
      end
      driver.step('Match details') do |form|
        field = form.fields.first
        field.index, field.check = 3, 7
        before = [form.index, field.text, field.index, field.check]
        form.game_room_hotkey_action(1).call
        assert([form.index, field.text, field.index, field.check] == before, 'F1 szczegółów zmienił fokus/tekst/caret')
        assert([SpeechOutput.calls.size - returned[0], NVDA.calls.size - returned[1]] == [1, 1], 'F1 szczegółów nie wrócił pojedynczym odczytem')
      end
      driver.step('Keyboard shortcuts', [27])
      driver.step('Match details', [27])
      driver.step('My tournaments', [27])
    end
    if mode == 'selection'
      driver.step('Match details', [27]) do |form|
        assert(form.fields.first.text.include?('Game: chess'), 'Szczegóły innego turnieju')
      end
      driver.step('My tournaments', [27])
    end
    driver.step('My tournaments', [27]) if mode == 'finish_exception'
    if primary
      observed = begin; screen.run; rescue Exception => error; error; end
      assert(observed.equal?(primary) && observed.cause.nil? && observed.backtrace == ['zamkniecie.rb:19'], 'Reentrant resume zamaskował primary przez lokalne zakończenie lease')
    else
      screen.run
    end
    if counts
      assert(SpeechOutput.calls.drop(counts[0]).empty? && NVDA.calls.drop(counts[1]).empty?, "Stara prezentacja po utracie lease: #{mode}")
    end
    assert(!driver.overrun, 'Aktywne wejście nie zakończyło się po unieważnieniu')
    driver.finish
    assert([program, program.class.app_runtime].all? { |port| port.managed_resources.size == 0 }, 'Ekran pozostawił zasoby')
    puts "PASS granica natywna: #{mode}"
  end
end
