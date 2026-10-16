# encoding: UTF-8
require_relative '../support/tournament_native'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/local_test_hub'
require_relative '../../lib/game_room_background'
include GameRoomTest::Assertions
H = TournamentLocalHubTest
T = GameRoomTournaments
GameRoomLocalization.boot(settings: {'interface_language' => 'en', 'known_languages' => ['en']})

# Dwa odrębne turnieje, każdy z wieloma własnymi meczami i rewanżami.
# Oba kierunki zmiany kursora turnieju chronią przed pozorną naprawą index=0.
[0, 1].product([:accept, :cancel]).each do |tournament_index, mode|
  Dir.mktmpdir('r1-wybor-', ENV.fetch('TMPDIR')) do |directory|
    program = TournamentMatchEntryTest.prepare(directory)
    hub = T::LocalTestHub.new(**H.args(program: program, clock: -> {201}))
    driver = TournamentNativeDriver.new
    screen = parent = status = matches = nil
    saved = {}; chain = []; listening = false
    complete = lambda do
      work = screen.instance_variable_get(:@readiness_work)
      assert(work, 'Brak rzeczywistego workera')
      wait_background_work(work)
      parent.update
    end
    trace = TracePoint.new(:call) do |event|
      if listening && event.self.equal?(matches) && event.method_id == :focus && event.path.tr('\\', '/').include?('/src/ui/controls/')
        chain << :native
      end
    end
    driver.open_test_participant
    driver.step('Choose a test participant', [13]) do |form|
      H.field(form, 'Test participant name').set_text('Alicja')
      form.index = form.fields.index(H.button(form, 'Use test participant'))
    end
    driver.step('Local tournament tests', [13]) do |form|
      form.index = form.fields.index(H.button(form, 'My matches — readiness and coordination'))
    end
    driver.step('My tournaments') do |form|
      parent = form; screen = hub.instance_variable_get(:@match_entry)
      H.button(form, 'Check status').press; complete.call
      tournaments = H.field(form, 'My tournaments')
      assert_equal(2, tournaments.options.size, 'Fixture nie ma dwóch turniejów')
      tournaments.index = tournament_index; tournaments.trigger(:move); complete.call
      matches = H.field(form, 'My matches'); matches.index = 2; matches.trigger(:move); complete.call
      status = H.field(form, 'Readiness and coordination')
      status.index, status.check = 2, 5
      form.index = form.fields.index(matches)
      saved = {selected_id: screen.controller.view[:selected_id], candidate: screen.controller.view[:candidate],
        match: screen.controller.view[:matches][2], options: matches.options.dup, field: form.index,
        caret: [status.index, status.check], status: status.text}
      assert_equal(tournament_index == 0 ? 'chess' : 'three_five_eight', saved[:candidate]['game_id'])
      matches.on(:before_focus) { chain << :before if listening }
      matches.on(:focus) { chain << :after if listening }
      H.button(form, 'Prepare local test plan').press
      complete.call
      # Jeden powrót bez dodatkowego Form#focus w helperze odtwarzania wyboru.
      assert_equal([:before, :native, :after], chain, 'Niepojedynczy łańcuch powrotu fokusu')
      assert_equal([1, 1], [SpeechOutput.calls.size - saved[:speech], NVDA.calls.size - saved[:braille]], 'Niepojedyncza mowa/brajl po modalu')
      listening = false
    end
    driver.step('Local test plan', [13]) do |form|
      text = H.field(form, 'Local test plan').text
      saved[:candidate]['matches'].each do |match|
        assert(text.include?("Match #{match['number']}, leg #{match['leg']}: #{match['players'].join(', ')}"), 'Niepełny podgląd planu')
      end
      form.index = form.fields.index(H.button(form, mode == :accept ? 'Accept local test plan' : 'Cancel'))
    end
    driver.on_resume = lambda do |closed|
      next unless closed.fields.first.header == 'Local test plan'
      assert(screen.instance_variable_get(:@busy), 'Resume poza busy')
      H.field(parent, 'My tournaments').index = 1 - tournament_index
      matches.index = 0; parent.index = 0
      status.index, status.check = 0, 0
      2.times do
        ['Ready', 'Prepare local test plan', 'Back'].each { |label| H.button(parent, label).press }
      end
      assert(!screen.instance_variable_get(:@readiness_pending), 'Reentry przejęło pending')
      saved[:speech], saved[:braille] = SpeechOutput.calls.size, NVDA.calls.size
      listening = true
    end
    driver.step('My tournaments') do |form|
      complete.call if mode == :accept
      assert_equal(tournament_index, H.field(form, 'My tournaments').index, 'Resume podmieniło turniej')
      assert_equal(saved[:selected_id], screen.controller.view[:selected_id], 'Model zgubił turniej')
      assert_equal(saved[:options], matches.options, 'Lista meczów innego turnieju')
      assert_equal(2, matches.index, 'Resume podmieniło mecz')
      assert_equal(saved[:field], form.index, 'Powrót na inne pole')
      assert_equal(saved[:caret], [status.index, status.check], 'Powrót zgubił caret/zaznaczenie')
      if mode == :cancel
        assert_equal(saved[:status], status.text, 'Anulowanie zmieniło status')
        assert_equal([], Dir.glob('**/sandbox-k03.json', base: directory), 'Cancel zapisał plan')
      else
        state = screen.instance_variable_get(:@readiness_state)
        assert_equal(saved[:match]['match_id'], state[:target][:match_ref]['match_id'], 'Akceptacja zmieniła target')
        H.button(form, 'Ready').press; complete.call
        state = screen.instance_variable_get(:@readiness_state)
        effect = state.fetch(:operation); receipt = effect.fetch(:receipt)
        assert_equal(:confirmed, effect[:state], 'Ready nie potwierdzone')
        assert_equal(effect[:operation_id], receipt['operation']['operation_id'], 'Inny UUID receipt')
        assert_equal(state[:target][:scope], receipt['operation']['request']['scope'], 'Inny scope Ready')
        assert_equal(state[:target][:match_ref], receipt['operation']['request']['match_ref'], 'Inny match_ref Ready')
        assert_equal(saved[:match]['match_id'], receipt['operation']['request']['match_ref']['match_id'], 'Zapis dotyczy innego meczu')
        members = saved[:match]['players'].map { |account| {'account' => account, 'kind' => 'human', 'role' => 'player'} }
        assert_equal(members, receipt['operation']['accepted_match']['members'], 'Zapis dotyczy innego składu')
        assert_equal(1, receipt['result']['ready_revision'], 'Reentry wysłało dodatkowe Ready')
        path = Dir.glob('**/sandbox-k03.json', base: directory)
        assert_equal(1, path.size, 'Nieoczekiwany zbiór magazynów')
        bytes = File.binread(File.join(directory, path.first)); disk = JSON.parse(bytes)
        assert_equal([receipt], disk['receipts'], 'Dysk nie zawiera dokładnego receipt')
        assert_equal(saved[:candidate], disk['plans'].first['candidate'], 'Dysk nie zawiera pokazanego pełnego planu')
        assert_equal(state[:target][:match_ref]['plan_id'], disk['plans'].first['plan_id'], 'Inny plan w scope Ready')
        assert(status.text.include?(effect[:operation_id]) && status.text.include?('Own readiness: ready; revision: 1'), 'Status nie opisuje potwierdzenia')
        if ENV['ENTRY_EVIDENCE']
          File.binwrite(File.join(ENV['ENTRY_EVIDENCE'], "r1-disk-#{tournament_index}.json"), bytes)
          File.write(File.join(ENV['ENTRY_EVIDENCE'], "r1-selection-#{tournament_index}.json"), JSON.pretty_generate({saved: saved, target: state[:target], operation: effect}), encoding: 'UTF-8')
        end
      end
      H.button(form, 'View details').press
    end
    driver.step('Match details', [27]) do |form|
      text = H.field(form, 'Match details').text
      assert(text.include?("Match ID: #{saved[:match]['match_id']}"), 'Szczegóły innego meczu')
      assert(text.include?("Game: #{saved[:candidate]['game_id']}"), 'Szczegóły innej gry')
      assert(text.include?(status.text), 'Szczegóły mają inny status')
    end
    driver.step('My tournaments', [27])
    driver.step('Local tournament tests', [27])
    trace.enable { hub.run }
    driver.finish
    assert_equal([0, 0], [program.managed_resources.size, program.class.app_runtime.managed_resources.size], 'Pozostały zasoby')
  end
  puts "PASS R1: turniej #{tournament_index}, #{mode}, dokładny wybór, dysk, szczegóły, caret i pojedynczy fokus"
end
