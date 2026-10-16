# encoding: UTF-8
require_relative '../support/ui'
require_relative '../support/tournament_local_hub'
require_relative '../support/tournament_entry_context'
require_relative '../../lib/tournaments/match_entry_screen'
include GameRoomTest::Assertions
G = GameRoomTournaments
E = TournamentEntryContextTest
[:program, :runtime].each do |target|
  program = E::Program.new
  runtime = program.class.app_runtime
  port = target == :program ? program : runtime
  manage = port.method(:manage)
  primary = NoMethodError.new('Błąd po rejestracji')
  primary.set_backtrace(['rejestracja.rb:14'])
  port.define_singleton_method(:manage) { |value| manage.call(value); raise primary, cause: nil }
  observed = begin
    G::EntryContext.new(program: program, runtime: runtime, owner_reader: -> { 'Alice' })
  rescue Exception => error; error
  end
  assert(observed.equal?(primary) && observed.cause.nil? && observed.backtrace == ['rejestracja.rb:14'], 'Zmieniono błąd manage')
  assert([program, runtime].all? { |owner| owner.managed_resources.size == 0 }, "Wyciek po częściowym manage #{target}")
end
puts 'PASS 05: częściowe manage obu rzeczywistych Registry zwolnione'
[:subscribe, :program, :runtime].each do |stage|
  program = E::Program.new
  runtime = program.class.app_runtime
  source = E::Events.new('alice')
  if stage == :subscribe
    subscribe = source.method(:subscribe)
    source.define_singleton_method(:subscribe) do |&listener|
      handle = subscribe.call(&listener)
      program.finalize
      handle
    end
  else
    port = stage == :program ? program : runtime
    manage = port.method(:manage)
    port.define_singleton_method(:manage) do |context|
      # Zakończenie następuje przed późnym wpisem do prawdziwego Registry.
      context.close
      manage.call(context)
    end
  end
  context = G::EntryContext.new(program: program, runtime: runtime, owner_reader: -> { 'Alice' }, account_events: source)
  3.times { context.close }
  assert(!context.current?(context.capture), 'Zakończona konstrukcja odzyskała ważność')
  assert(source.listeners.empty?, "Późny listener pozostał po #{stage}")
  assert([program, runtime].all? { |owner| owner.managed_resources.size == 0 }, "Późny manage pozostał po #{stage}")
end
puts 'PASS 06: reentrant subscribe/manage, oba Registry, bezpośredni brak listenerów i wielokrotne close'
