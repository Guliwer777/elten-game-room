# encoding: UTF-8
require_relative '../support/tournament_ft2b1_ui_probe'
include GameRoomTest::Assertions
T = GameRoomTournaments
results = []
[false, true].each do |with_cause|
  program = TournamentEntryContextTest::Program.new
  calls = 0
  armed = false
  primary = T::Publication::Invalid.new(:invalid_fields)
  cause = with_cause ? IOError.new('Przyczyna callbacka') : nil
  primary.set_backtrace(['current-callback:17'])
  reader = -> { calls += 1; raise primary, cause: cause if armed; 'Owner' }
  context = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: reader)
  lease = context.capture
  begin
    before = calls
    armed = true
    observed = nil
    begin
      context.current?(lease)
    rescue Exception => error
      observed = error
    end
    results << {with_cause: with_cause, same: observed.equal?(primary), cause: observed && observed.cause.equal?(cause),
      backtrace: observed&.backtrace, calls: calls - before}
  ensure
    armed = false
    context.close; program.finalize; program.class.app_runtime.close
  end
end
[nil, '', 42].each do |bad|
  program = TournamentEntryContextTest::Program.new
  value = 'Owner'
  context = T::EntryContext.new(program: program, runtime: program.class.app_runtime, owner_reader: -> { value })
  lease = context.capture
  begin
    value = bad
    assert_equal(false, context.current?(lease), 'Niepoprawna wartość nie unieważniła lease')
    value = 'Owner'
    assert_equal(false, context.current?(lease), 'Powrót poprawnej wartości ożywił lease')
  ensure
    context.close; program.finalize; program.class.app_runtime.close
  end
end
TournamentFT2B1UI.evidence('current', results)
assert(results.all? { |r| r[:same] && r[:cause] && r[:backtrace] == ['current-callback:17'] && r[:calls] == 1 }, 'Wyjątek callbacka nie jest błędem zwróconej wartości')
puts 'PASS current?: jednokrotny callback, dokładny primary/cause/backtrace; niepoprawna wartość i zatrzask'
