# encoding: UTF-8
require_relative '../support/tournament_local_readiness'
include TournamentLocalReadinessSupport
include GameRoomTest::Assertions
T=GameRoomTournaments
path=File.expand_path('../../lib/tournaments/readiness_history.rb',__dir__)
require path if File.file?(path)
assert(T.const_defined?(:ReadinessHistory),'Brak publicznego ograniczonego czytnika dawnych intencji')
sandbox do |ctx|
  f=prepared(ctx)
  ready=f[:service].declare(request:f[:request])
  assert_equal(:confirmed,ready[:state])
  operation=ready[:receipt]['operation']
  assert_equal(ready[:receipt],f[:backend].store(operation:operation))
  assert_equal(1,f[:service].current(**f[:target])[:current]['ready_revision'])
  withdraw=f[:request].merge('availability'=>'withdrawn','expected_ready_revision'=>1)
  rename=File.method(:rename)
  fired=false
  File.define_singleton_method(:rename) do |from,to|
    value=rename.call(from,to)
    if to.end_with?('sandbox-k03.json') && !fired
      fired=true
      raise IOError,'Utracona odpowiedź po rename sandboxa'
    end
    value
  end
  begin
    uncertain=f[:service].declare(request:withdraw)
  ensure
    File.define_singleton_method(:rename,rename)
  end
  assert_equal(:unknown,uncertain[:state])
  assert(uncertain[:operation_id])
  history=T::ReadinessHistory.new(directory:f[:directory],context:-> {f[:context]},identity:f[:backend].identity)
  records=history.records(**f[:target])
  assert_equal(2,records.size)
  assert_equal(uncertain[:operation_id],records.find { |item| item['status']=='attempted' }['operation']['operation_id'])
  fresh=T::ReadinessService.new(port:f[:backend],trusted_identity:f[:backend].identity,directory:f[:directory],context:-> {f[:context]})
  assert_equal(:blocked,fresh.declare(request:f[:request].merge('expected_ready_revision'=>2))[:state])
  f[:backend].define_singleton_method(:store) { |**| raise 'Readback nie wysyła' }
  result=fresh.reconcile(**f[:target],operation_id:uncertain[:operation_id])
  assert_equal(:confirmed,result[:state])
  assert_equal('withdrawn',result[:receipt]['result']['state'])
  assert_equal(2,fresh.current(**f[:target])[:current]['ready_revision'])
  assert_equal('ready',fresh.reconcile(**f[:target],operation_id:ready[:operation_id])[:receipt]['result']['state'])
  assert(records.frozen? && records.first['operation']['request'].frozen?)
end
puts 'PASS withdrawn po confirmed, afterrename unknown, historia UUID, readback bez resend'
