# encoding: UTF-8
require_relative 'tournament_environment'
require 'json'
require 'tmpdir'
require 'fileutils'
path = File.expand_path('../../lib/tournaments/readiness_service.rb', __dir__)
require path if File.file?(path) && !defined?(GameRoomTournaments::ReadinessService)

module TournamentReadinessFixture
  module_function
  def assert(value, message)
    raise "Asercja: #{message}" unless value
  end
  def copy(value)
    JSON.parse(JSON.generate(value))
  end
  def scope
    {'app_uuid'=>'fixture-app','backend_identity'=>'fixture:k03','tournament_id'=>'turniej'}
  end
  def match_ref
    {'plan_id'=>'plan-1','match_id'=>'mecz-1','leg'=>1,'roster_generation'=>'sklad-1'}
  end
  def request(state='ready', revision=0)
    {'version'=>1,'scope'=>scope,'match_ref'=>match_ref,'availability'=>state,
      'expected_ready_revision'=>revision,'policy_ref'=>'polityka-testowa'}
  end
  def isolated
    Dir.mktmpdir('k03-', ENV.fetch('ENTRY_SCRATCH')) { |dir| yield dir }
  end
  def service(dir, port, source)
    GameRoomTournaments::ReadinessService.new(port:port,trusted_identity:'fixture:k03',directory:dir,context:source.method(:call))
  end

  # Wyłącznie testowy producent zdarzeń, nie obserwator Session.name.
  class Context
    attr_reader :events
    def initialize(account='alice')
      @value={'account'=>account,'backend_identity'=>'fixture:k03','runtime_id'=>'runtime-A',
        'runtime_epoch'=>1,'auth_epoch'=>1,'backend_epoch'=>1,'cancelled'=>false}
      @events=[]
    end
    def emit(kind, value)
      @events << [kind,value]
      field, epoch = {account:['account','auth_epoch'],backend:['backend_identity','backend_epoch'],runtime:['runtime_id','runtime_epoch'],cancel:['cancelled','runtime_epoch']}.fetch(kind)
      @value[field]=value; @value[epoch]+=1
    end
    def call
      TournamentReadinessFixture.copy(@value)
    end
  end

  # Symulacja przyszłego serwera. Nie potwierdza ACL ani CAS sieci.
  class Port
    attr_accessor :hook, :view, :capabilities
    attr_reader :calls, :operations
    def initialize(account='alice')
      @calls=[]; @operations={}; @hook=nil
      @capabilities=%w[per_account_acl own_readback accepted_match ready_cas start_gate_invalidation durable_operation no_hidden_retry].to_h { |k| [k,1] }
      @view={'status'=>'confirmed','identity'=>identity,'scope'=>TournamentReadinessFixture.scope,
        'match_ref'=>TournamentReadinessFixture.match_ref,'account'=>account,
        'accepted_match'=>{'status'=>'confirmed','plan_digest'=>'a'*64,'full_roster'=>true,'roles_status'=>'confirmed',
          'members'=>%w[alice bob celina].map { |a| {'account'=>a,'kind'=>'human','role'=>'player'} }},
        'policy'=>{'status'=>'confirmed','ref'=>'polityka-testowa','allows'=>%w[ready withdrawn]},
        'current'=>{'state'=>'unknown','ready_revision'=>0,'server_time'=>100},'phase'=>'not_started'}
    end
    def identity
      'fixture:k03'
    end
    def event(name, value)
      @calls << name; @hook.call(name,value) if @hook; value
    end
    def negotiate(scope:, required:)
      event(:negotiate,{'status'=>'confirmed','identity'=>identity,'scope'=>scope,
        'capabilities'=>TournamentReadinessFixture.copy(@capabilities),'authorization'=>'own_account','retention'=>'match_lineage','max_bytes'=>65_536})
    end
    def receipt(operation, status, result=nil)
      {'status'=>status,'operation'=>TournamentReadinessFixture.copy(operation),
        'request_digest'=>operation['request_digest'],'reason'=>status,'result'=>result}
    end
    def store(operation:)
      event(:store_before,operation)
      r=operation['request']
      if @view['phase']=='started' || !r['expected_ready_revision'].eql?(@view['current']['ready_revision'])
        answer=receipt(operation,'conflict')
      else
        @view['current']={'state'=>r['availability'],'ready_revision'=>@view['current']['ready_revision']+1,'server_time'=>101}
        answer=receipt(operation,'confirmed',@view['current'].merge('account'=>@view['account'],'invalidated_grants'=>['grant-test']))
      end
      @operations[operation['operation_id']]=TournamentReadinessFixture.copy(answer)
      event(:store_after,TournamentReadinessFixture.copy(answer))
    end
    def lookup(operation:)
      answer=@operations[operation['operation_id']] || receipt(operation,'unknown')
      event(:lookup,TournamentReadinessFixture.copy(answer))
    end
    def snapshot(scope:, match_ref:)
      event(:snapshot,TournamentReadinessFixture.copy(@view))
    end
  end
end
