# encoding: UTF-8
require_relative 'tournament_coordination_port'

# Rzeczywisty service/journal/MatchBinding; port wyłącznie jawna SYMULACJA.
module TournamentCoordinationFixCases
  F=TournamentCoordinationFixture
  C=GameRoomTournaments::CoordinationContract
  S=GameRoomTournaments::CoordinationService
  class AssertionFailure < StandardError; end
  module_function

  def assert(value, message)
    raise AssertionFailure,message unless value
  end

  def service(port, directory, context=F.context)
    S.new(port:port,trusted_identity:'fixture:owner',directory:directory,
      registry:TournamentMatchFixture.registry,context: -> { context })
  end

  def result(value)
    value.merge(binding:value[:binding]&.to_h)
  end

  def mutations(port)
    [port.calls.count(:reserve_before),port.calls.count(:create_before)]
  end

  def stored(dir, kind='create_bind')
    request=F.request;port=TournamentCoordinationPort.new(request);context=F.context
    event=kind=='create_bind' ? :create_stored : :reserve_after
    port.hook=->(point,_) { raise C::PortUnavailable,'Symulowana utrata odpowiedzi po store' if point==event }
    first=service(port,dir,context).request_match(request:request)
    assert(first[:state]==:unknown && first[:operation_id]==port.operations.fetch(kind)['operation_id'],'Fixture: utrwalony skutek z unknown')
    port.hook=nil
    [request,port,context,first]
  end

  def lifecycle(port, mode)
    case mode
    when :withdrawn
      port.ready['bob']={'state'=>'withdrawn','revision'=>'ready-2'}
      port.grant=nil
    when :later
      port.ready['bob']={'state'=>'later','revision'=>'ready-2'}
      port.grant=nil
    when :invalidated then port.grant=nil
    when :expired then port.time=190
    when :window_end then port.time=200
    end
  end

  def bound(answer, receipt)
    op=receipt.fetch('operation');request=op.fetch('request')
    expected=request.reject { |k,_| %w[window visibility].include?(k) }.merge(
      'reservation'=>op['preconditions']['grant'].slice('id','revision','fencing','ready_versions'),
      'create'=>{'operation_id'=>op['operation_id'],'proof_ref'=>receipt['receipt']},
      'native_uuid'=>receipt['result']['native_uuid'],'table_id'=>receipt['result']['table_id'])
    assert(answer[:state]==:bound && answer[:operation_id]==op['operation_id'],"Historyczny klucz/binding: #{result(answer).inspect}")
    assert(answer[:binding].is_a?(GameRoomTournaments::MatchBinding) && answer[:binding].to_h.eql?(expected),'Realny MatchBinding pełnego pierwotnego spec')
    assert(!answer.key?(:start_allowed) && !answer[:binding].to_h.key?('start_allowed'),'DTO nie nadaje zgody startu')
  end

  def run(cases, label)
    results=cases.map do |name,test|
      row={name:name,pid:Process.pid}
      GameRoomTest::TemporaryDirectory.create('coord-fix1-') do |dir|
        row[:scratch]=dir
        cwd=Dir.pwd
        begin
          test.call(dir,row)
          row[:status]='PASS'
        rescue AssertionFailure => error
          row[:status]='FAIL';row[:assertion]=error.full_message
        ensure
          assert(File.identical?(cwd,Dir.pwd),'Scenariusz nie odtworzył cwd')
          row[:journals]=Dir.glob(File.join(dir,'**','*.json')).map { |p| {path:p,raw:File.binread(p).force_encoding('UTF-8')} }
        end
      end
      puts JSON.generate(row)
      row
    end
    File.write(File.join(ENV.fetch('COORD_EVIDENCE_DIR'),label+'-cases.json'),JSON.pretty_generate(results))
    puts JSON.generate({suite:label,total:results.length,passed:results.count { |r| r[:status]=='PASS' }})
    exit(results.all? { |r| r[:status]=='PASS' } ? 0 : 1)
  end
end
