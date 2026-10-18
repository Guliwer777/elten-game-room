# encoding: UTF-8
require_relative 'tournament_coordination_port'

# Plikowa usługa TESTOWA. Jej flock symuluje przyszłą transakcję serwera,
# nie jest dowodem globalnej atomowości ani adapterem wdrożonego API.
class TournamentCoordinationFilePort < TournamentCoordinationPort
  attr_reader :state_path
  def initialize(request, state_path:, account:, fault:nil)
    super(request,account:account)
    @state_path,@fault=state_path,fault
    root=File.realpath(File.dirname(state_path))
    scratch=File.realpath(GameRoomTest::TemporaryDirectory.parent)
    raise 'Usługa poza scratch' unless root.downcase.start_with?(scratch.downcase+File::SEPARATOR)
    transact do |state|
      state['matches'][request['match_id']] ||= {'request'=>copy(request),'ready'=>copy(@ready),'grant'=>nil,'operations'=>{}}
    end
  end

  def transact
    File.open(@state_path+'.lock',File::RDWR|File::CREAT,0o600) do |lock|
      lock.flock(File::LOCK_EX)
      state=File.exist?(@state_path) ? JSON.parse(File.binread(@state_path)) : {'matches'=>{},'busy'=>{},'calls'=>[],'fencing'=>0,'time'=>150}
      value=yield state
      bytes=JSON.generate(state)
      temporary=@state_path+'.tmp-'+Process.pid.to_s
      File.open(temporary,'wb') { |f| f.write(bytes);f.flush;f.fsync }
      File.rename(temporary,@state_path)
      copy(value)
    end
  end

  def snapshot(request:)
    transact do |state|
      row=state['matches'].fetch(request['match_id'])
      @request,@ready,@grant,@operations,@time=row.values_at('request','ready','grant','operations')+[state['time']]
      super(request:request)
    end
  end

  def lookup(scope:,kind:,operation_id:)
    transact do |state|
      state['calls'] << {'kind'=>'lookup','operation_id'=>operation_id,'account'=>@account,'pid'=>Process.pid}
      state['matches'].values.flat_map { |r| r['operations'].values }.find { |r| r['operation_id']==operation_id && r['kind']==kind && r['scope'].eql?(scope) }
    end
  end

  def reserve(operation:)
    event(:reserve_before,operation)
    result=transact do |state|
      state['calls'] << {'kind'=>'reserve','operation_id'=>operation['operation_id'],'account'=>@account,'pid'=>Process.pid}
      row=state['matches'].fetch(operation['request']['match_id'])
      previous=row['operations']['reserve']
      next previous if previous && previous['operation'].eql?(operation)
      accounts=row['ready'].keys
      if previous || accounts.any? { |a| state['busy'].key?(a) }
        next refusal(operation,'conflict')
      end
      unless row['request'].eql?(operation['request']) && row['ready'].values.all? { |r| r['state']=='ready' } &&
          row['ready'].transform_values { |r| r['revision'] }.eql?(operation['preconditions']['ready_versions']) && open?(state,operation)
        next refusal(operation,'refused')
      end
      state['fencing']+=1
      grant={'id'=>'reservation-'+operation['operation_id'],'revision'=>'revision-1','fencing'=>state['fencing'],
        'holder_account'=>@account,'coordinator_epoch'=>'epoch-1','expires_at'=>190,
        'ready_versions'=>operation['preconditions']['ready_versions'],'window'=>operation['request']['window']}
      row['grant']=grant
      accounts.each { |a| state['busy'][a]=operation['operation_id'] }
      row['operations']['reserve']=response(operation,grant)
    end
    lose!(:reserve_after)
    event(:reserve_after,result)
  end

  def create_bind(operation:)
    event(:create_before,operation)
    lose!(:create_before)
    result=transact do |state|
      state['calls'] << {'kind'=>'create_bind','operation_id'=>operation['operation_id'],'account'=>@account,'pid'=>Process.pid}
      row=state['matches'].fetch(operation['request']['match_id'])
      previous=row['operations']['create_bind']
      next previous if previous && previous['operation'].eql?(operation)
      unless previous.nil? && row['grant'].eql?(operation['preconditions']['grant']) && row['grant']['holder_account']==@account && open?(state,operation)
        next refusal(operation,'conflict')
      end
      row['operations']['create_bind']=response(operation,{'native_uuid'=>SecureRandom.uuid,'table_id'=>state['fencing'],
        'binding_id'=>'binding-'+operation['operation_id'],'binding_revision'=>'binding-r1','creator_account'=>@account,'game_instance'=>nil})
    end
    lose!(:create_stored)
    @endpoint_sessions << result['result']['native_uuid'] if result['status']=='confirmed'
    lose!(:create_after)
    result
  end

  def refusal(operation,status)
    response(operation,nil).merge('status'=>status,'reason'=>status,'receipt'=>nil,'resource_revision'=>nil)
  end

  def open?(state,operation)
    w=operation['request']['window']
    state['time']>=w['opens'] && state['time']<w['closes']
  end

  def lose!(point)
    raise GameRoomTournaments::CoordinationContract::PortUnavailable,'Testowa utrata odpowiedzi' if @fault==point.to_s
  end
end
