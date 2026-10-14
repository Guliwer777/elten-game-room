# encoding: UTF-8
require_relative '../support/tournament_local_readiness'
include TournamentLocalReadinessSupport
include GameRoomTest::Assertions
T=GameRoomTournaments
C=T::ReadinessContract
%w[chess three_five_eight uno audio_ball].each do |game|
  sandbox do |ctx|
    f=prepared(ctx,game:game,names:%w[Alicja Bob Celina Dawid])
    before=Marshal.dump(f[:anchor])
    result=f[:service].declare(request:f[:request])
    assert_equal(:confirmed,result[:state])
    assert_equal(before,Marshal.dump(f[:backend].plans.first))
    assert_equal(f[:candidate].to_h['matches'].size,f[:anchor]['candidate']['matches'].size)
    assert_equal('unassigned',f[:anchor]['candidate']['roles_teams'])
  end
end
sandbox do |ctx|
  f=prepared(ctx,game:'three_five_eight',names:%w[Alicja Bob Celina Dawid])
  accepted=f[:service].declare(request:f[:request])
  old=Marshal.dump(f[:anchor])
  ctx.now=150
  assert_equal('confirmed',ctx.workspace('Ewa').join(1)['status'])
  ctx.now=201
  refused=f[:service].declare(request:f[:request].merge('availability'=>'withdrawn','expected_ready_revision'=>1))
  assert_equal(:blocked,refused[:state])
  assert_equal('ready',f[:service].reconcile(**f[:target],operation_id:accepted[:operation_id])[:receipt]['result']['state'])
  assert_equal(old,Marshal.dump(f[:backend].plans.first))
  fresh=f[:source].call(f[:candidate].to_h['publication_ref'])
  new_plan=f[:backend].accept(candidate:fresh)
  assert(new_plan['plan_id']!=f[:anchor]['plan_id'])
  assert_equal(2,f[:backend].plans.size)
end
[false,true].each do |with_cause|
  sandbox do |ctx|
    f=prepared(ctx)
    cause=ArgumentError.new('Pierwotna przyczyna') if with_cause
    primary=begin
      raise NoMethodError.new('Pierwotna awaria zapisu'),cause:cause
    rescue NoMethodError => error
      error
    end
    primary.set_backtrace(['lokalny_primary.rb:19'])
    trace=primary.backtrace.dup
    original=File.method(:open)
    File.define_singleton_method(:open) do |path,*args,**options,&block|
      file=original.call(path,*args,**options,&block)
      if path.to_s.include?('sandbox-k03.json.tmp-')
        native_close=file.method(:close)
        file.define_singleton_method(:write) { |_bytes| raise primary,cause:primary.cause }
        file.define_singleton_method(:close) { native_close.call; raise Exception,'Wtórna awaria cleanup' }
      end
      file
    end
    begin
      error=assert_raises(NoMethodError) { f[:service].declare(request:f[:request]) }
      assert(error.equal?(primary))
      assert(error.cause.equal?(cause))
      assert_equal(trace,error.backtrace)
    ensure
      File.define_singleton_method(:open,original)
    end
    assert_equal(1,f[:backend].plans.size)
    assert_equal([],Dir.glob(File.join(ctx.directory,'k03','*.tmp-*')))
    assert_equal(0,f[:backend].snapshot(**f[:target])['current']['ready_revision'])
  end
end
puts 'PASS 4 rodziny planów, pełne źródło/niezmienna kotwica/nowa akceptacja, exact primary/cause/backtrace i cleanup'
