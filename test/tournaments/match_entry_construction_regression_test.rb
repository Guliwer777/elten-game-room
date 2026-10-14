# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/match_entry_screen'
include GameRoomTest::Assertions
G = GameRoomTournaments
E = TournamentEntryContextTest
[:controller, :form].product([false, true]).each do |stage, broken_cleanup|
  program = E::Program.new
  runtime = program.class.app_runtime
  workspace = Object.new
  count = 0
  primary = NoMethodError.new('Błąd częściowej konstrukcji ekranu')
  primary.set_backtrace(['konstrukcja.rb:23'])
  workspace.define_singleton_method(:actor) do
    count += 1
    raise primary, cause: nil if stage == :controller && count == 2
    'Bob'
  end
  owner = G::LocalTestDialogs::Owner.new(-> { 'Alice' }, ->(_message) {})
  release = program.method(:release)
  program.define_singleton_method(:release) { |resource| release.call(resource); raise IOError, 'Wtórny close' if broken_cleanup }
  screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
  screen.define_singleton_method(:build_form) { raise primary, cause: nil } if stage == :form
  observed = begin; screen.run; rescue Exception => error; error; end
  assert(observed.equal?(primary) && observed.cause.nil? && observed.backtrace == ['konstrukcja.rb:23'], 'Ekran zamaskował primary')
  assert([program, runtime].all? { |port| port.managed_resources.size == 0 }, "Wyciek zasobów na etapie #{stage}")
end
puts 'PASS 05: konstrukcja kontrolera/formularza i wtórny close bez retencji/zmiany primary'
[:restore, :finish].each do |stage|
  program = E::Program.new
  runtime = program.class.app_runtime
  owner = G::LocalTestDialogs::Owner.new(-> { 'Alice' }, ->(_message) {})
  workspace = Struct.new(:actor).new('Bob')
  primary = NoMethodError.new('Pierwotny błąd ekranu')
  primary.set_backtrace(['ekran.rb:47'])
  secondary = IOError.new('Wtórny błąd prezentacji')
  screen = G::MatchEntryScreen.new(program: program, workspace: workspace, owner: owner)
  resumed = false
  if stage == :restore
    build = screen.method(:build_form)
    screen.define_singleton_method(:build_form) do
      build.call
      instance_variable_get(:@form).define_singleton_method(:focus) { raise secondary, cause: nil }
      raise primary, cause: nil
    end
  else
    release = program.method(:release)
    program.define_singleton_method(:release) { |value| release.call(value); raise primary, cause: nil }
    screen.define_singleton_method(:build_form) do
      form = Object.new
      form.define_singleton_method(:resume) { resumed = true; raise secondary, cause: nil }
      @form = form
      finish
    end
  end
  observed = begin; screen.run; rescue Exception => error; error; end
  assert(observed.equal?(primary) && observed.cause.nil? && observed.backtrace == ['ekran.rb:47'], "Wtórny #{stage} zamaskował primary")
  assert(resumed, 'Nie zakończono formularza po błędzie close') if stage == :finish
  assert(screen.controller.context.cleanup_attempts.any? { |receipt| receipt[:failures].any? { |error| error[:message] == secondary.message } }, 'Brak przypisanego błędu prezentacji')
  assert([program, runtime].all? { |port| port.managed_resources.size == 0 }, 'Cleanup ekranu pozostawił zasoby')
end
puts 'PASS 05: restore/finish/ensure nie maskują primary; resume mimo awarii close'
