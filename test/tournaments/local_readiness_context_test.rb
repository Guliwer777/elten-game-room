# encoding: UTF-8
require_relative '../support/tournament_match_entry'
require_relative '../../lib/tournaments/entry_context'
require_relative '../../lib/tournaments/readiness_contract'
include GameRoomTest::Assertions
T=GameRoomTournaments
file=File.expand_path('../../lib/tournaments/local_readiness_session.rb',__dir__)
require file if File.file?(file)
assert(T.const_defined?(:LocalReadinessSession),'Brak rzeczywistego producenta epok sandboxa')
Dir.mktmpdir('d2b-epochs-',ENV.fetch('TMPDIR')) do |directory|
  program=TournamentEntryContextTest::Program.new(directory)
  session=T::LocalReadinessSession.new
  events=[]
  listener=session.actor_events.subscribe { |event| events << event }
  session.choose_actor('Alicja')
  owner=-> {'RealOwner'}
  entry=T::EntryContext.new(program:program,runtime:program.class.app_runtime,owner_reader:owner,account_events:session.actor_events)
  lease=entry.capture
  session.bind_backend('local-test-k03:test')
  context=session.context(program:program,owner_reader:owner,entry:entry,lease:lease,actor:'Alicja',identity:'local-test-k03:test')
  first=context.call
  assert_equal(false,first['cancelled'])
  session.choose_actor('Bob')
  session.choose_actor('Alicja')
  assert_equal(%w[alicja bob alicja],events.map { |event| event[:value] })
  assert(events.each_cons(2).all? { |a,b| b[:epoch] > a[:epoch] })
  assert_equal(true,context.call['cancelled'])
  assert(!entry.current?(lease))
  context.close
  entry.close
  listener.close
  assert_equal(0,session.actor_events.listener_count)
  assert_equal(0,session.backend_events.listener_count)
  entry=T::EntryContext.new(program:program,runtime:program.class.app_runtime,owner_reader:owner,account_events:session.actor_events)
  context=session.context(program:program,owner_reader:owner,entry:entry,lease:entry.capture,actor:'Alicja',identity:'local-test-k03:test')
  session.change_backend('local-test-k03:other')
  session.change_backend('local-test-k03:test')
  assert(context.call['cancelled'])
  context.close; entry.close
  entry=T::EntryContext.new(program:program,runtime:program.class.app_runtime,owner_reader:owner,account_events:session.actor_events)
  context=session.context(program:program,owner_reader:owner,entry:entry,lease:entry.capture,actor:'Alicja',identity:'local-test-k03:test')
  assert(!context.call['cancelled'])
  program.class.app_runtime.close
  assert(context.call['cancelled'])
  context.close; entry.close; session.close
  assert_equal(0,program.managed_resources.size)
  assert_equal(0,session.actor_events.listener_count)
  assert_equal(0,session.backend_events.listener_count)
end
puts 'PASS emitowane ABA aktora/backendu, runtime close i brak osieroconych subskrypcji'
