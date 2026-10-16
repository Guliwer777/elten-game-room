# encoding: UTF-8
require_relative 'tournament_environment'
require_relative 'tournament_coordination_fixture'

# Jawna SYMULACJA przyszłego portu. Nigdy adapter produkcyjny ani LiveSessions.
class TournamentCoordinationPort
  attr_accessor :hook, :capabilities, :time, :ready, :grant, :competing, :delegation
  attr_reader :calls, :operations, :endpoint_sessions
  def initialize(request, account: 'alice')
    @request, @account = Marshal.load(Marshal.dump(request)), account
    @calls, @operations, @endpoint_sessions = [], {}, []
    @time, @competing, @delegation = 150, nil, nil
    @ready = request['players'].to_h { |p| [p['account'], {'state'=>'ready','revision'=>'ready-1'}] }
    @capabilities = %w[sealed_plan full_ready atomic_reserve durable_create_bind shared_lookup].to_h { |k| [k,1] }
  end
  def copy(value)
    Marshal.load(Marshal.dump(value))
  end
  def event(name, value)
    @calls << name
    @hook.call(name, value) if @hook
    value
  end
  def identity
    'fixture:owner'
  end
  def negotiate(scope:, required:)
    event(:negotiate, {'status'=>'confirmed','identity'=>identity, 'scope'=>scope,
      'capabilities'=>@capabilities,'retention'=>'match_lineage',
      'authorization'=>'authenticated_participant_or_delegate','max_bytes'=>262144})
  end
  def snapshot(request:)
    event(:snapshot, copy({'status'=>'confirmed','read_id'=>'snapshot-1','scope'=>@request['scope'],
      'request'=>@request,'seal_status'=>'confirmed','resource_revision'=>'snapshot-r1',
      'server_time'=>{'seconds'=>@time,'source'=>'test-service-clock'}, 'ready'=>@ready,
      'authorized_account'=>@account,'delegation'=>@delegation,'competing_operation'=>@competing,
      'grant'=>@grant,'shared'=>@operations.transform_values { |v| v['operation'] }}))
  end
  def reserve(operation:)
    event(:reserve_before, operation)
    @grant = {'id'=>'reservation-1','revision'=>'reservation-r1','fencing'=>7,
      'ready_versions'=>@ready.transform_values { |r| r['revision'] },'window'=>@request['window'],
      'holder_account'=>@account,'coordinator_epoch'=>'coord-1','expires_at'=>190}
    result = response(operation, @grant)
    @operations['reserve'] = copy(result)
    event(:reserve_after, copy(result))
  end
  def create_bind(operation:)
    event(:create_before, operation)
    result = response(operation, {'native_uuid'=>'11111111-2222-3333-4444-555555555555',
      'table_id'=>42,'binding_id'=>'binding-1','binding_revision'=>'binding-r1','creator_account'=>@account,
      'game_instance'=>nil})
    @operations['create_bind'] = copy(result)
    event(:create_stored, copy(result))
    @endpoint_sessions << result['result']['native_uuid']
    event(:create_after, copy(result))
  end
  def response(operation, result)
    {'status'=>'confirmed','scope'=>operation['request']['scope'],'kind'=>operation['kind'],
      'operation_id'=>operation['operation_id'],'request_digest'=>operation['request_digest'],
      'operation'=>copy(operation),'resource_revision'=>'result-r1','server_time'=>{'seconds'=>@time,'source'=>'test-service-clock'},
      'reason'=>'confirmed','receipt'=>"receipt-#{operation['kind']}",'result'=>copy(result)}
  end
  def lookup(scope:, kind:, operation_id:)
    record=@operations[kind]
    value=record && record['operation_id']==operation_id ? copy(record) : nil
    event(:lookup, value)
  end
end
