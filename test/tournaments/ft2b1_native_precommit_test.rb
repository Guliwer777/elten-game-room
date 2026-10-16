# encoding: UTF-8
require_relative '../support/tournament_ft2b1_native_support'
require EltenTestHost.file('src/eapi/server_clock.rb')
include GameRoomTest::Assertions
N=TournamentFT2B1Native
T=N::T
class FT2B1NativePrecommitProvider < T::LocalFixedTeamNativeProvider
  attr_reader :transaction, :failure, :reached
  def initialize(stage)
    @stage,@failure,@reached=stage,IOError.new("Awaria #{@stage}"),[]
  end
  def open(**args)
    @reached << :open
    raise @failure if @stage==:open
    @transaction=super
    stage,failure,reached=@stage,@failure,@reached
    if stage==:create
      endpoint=@transaction.program.live_sessions
      endpoint.define_singleton_method(:create) { |**_| reached << :create;raise failure }
    elsif [:metadata,:exact].include?(stage)
      original=@transaction.method(:metadata)
      @transaction.define_singleton_method(:metadata) do |**input|
        reached << stage
        raise failure if stage==:metadata
        data=T::CoordinationContract.copy(original.call(**input))
        data['metadata']['name']='Inny legalny pokój'
        data
      end
    elsif stage==:dump
      @transaction.define_singleton_method(:dump) { reached << :dump;raise failure }
    end
    @transaction
  end
end
rows=[]
[:open,:create,:metadata,:dump,:exact].each do |stage|
  fixture=N.fixture(stage.to_s)
  begin
    N.ready(fixture,0)
    provider=FT2B1NativePrecommitProvider.new(stage)
    N.execute(fixture,provider: provider) do |execution|
      storage=execution.instance_variable_get(:@storage)
      before=JSON.parse(File.binread(storage.path))
      failure=nil
      (result,calls)=N.observed do
        begin
          execution.request_match
        rescue IOError => error
          failure=error
          nil
        end
      end
      assert_equal(true,provider.reached.include?(stage),stage.to_s)
      if stage==:exact
        assert_equal(:native_target_mismatch,result[:reason])
      else
        assert_equal(provider.failure.object_id,failure&.object_id,stage.to_s)
      end
      document=JSON.parse(File.binread(storage.path))
      assert_equal(before['native'],document['native'],stage.to_s)
      assert_equal(true,document['executions'].values.all? { |row| row['target'].nil? && !row['operations'].key?('create_bind') })
      assert_equal(true,provider.transaction.program.live_sessions.closed?) if provider.transaction
      (reconciled,later)=N.observed { execution.reconcile }
      assert_equal(:unknown,reconciled[:state],reconciled.inspect)
      assert_equal([],later,'Readback nie może próbować ponownego create')
      assert_equal(document,JSON.parse(File.binread(storage.path)))
      rows << {stage: stage,reached: provider.reached,reason: result && result[:reason],error: failure&.message,calls: calls,reconcile: reconciled,later_calls: later,native: document['native']}
    end
  ensure
    N.close(fixture)
  end
end
File.binwrite(File.join(ENV.fetch('ENTRY_EVIDENCE'),'precommit.json'),JSON.pretty_generate(rows))
puts 'PASS pięć awarii przed commit, osiągnięte bramki, brak publikacji core/target/receipt i brak retry po readback'
