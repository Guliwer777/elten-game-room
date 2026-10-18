# encoding: UTF-8
require_relative '../support/tournament_readiness_fixture'
F=TournamentReadinessFixture
class ReadinessCleanupFatal < Exception; end

# Obserwujemy prawdziwe File i nie podmieniamy żadnej metody serwisu/dziennika.
# Ratunkowy close jest wyłącznie po zapisanym FAIL; nigdy nie zalicza próby.
module ReadinessCleanupResources
  module_function
  def logical_path(path)
    File.expand_path(path.tr('\\', '/').sub(%r{\A//\?/}, ''))
  end

  def run(target:, primary_class:, cause_kind:, ambient:, secondary:)
    label=[target,primary_class && primary_class.name,cause_kind,ambient,secondary].join('/')
    F.isolated do |dir|
      handles=[]; observations={label:label}; failed=true
      port=F::Port.new; source=F::Context.new
      primary=primary_class && primary_class.new('Pierwotny błąd zasobu')
      cause=cause_kind==:existing ? ArgumentError.new('Bezpośrednia przyczyna') : nil
      if primary
        begin
          raise primary,cause:cause
        rescue Exception => captured
          F.assert(captured.equal?(primary),'Przygotowano właściwy wyjątek')
        end
        primary.set_backtrace(['pierwotny-zasob:7'])
      end
      secondary_error=ReadinessCleanupFatal.new('Błąd cleanup')
      secondary_error.set_backtrace(['cleanup-zasob:9'])
      cleanup=false; guards=0; injected=false; cleanup_hit=false
      reader=-> do
        if cleanup
          guards+=1
          wanted=secondary.to_s.start_with?('pre_') ? 1 : 2
          if !cleanup_hit && guards==wanted && !%i[callback_exception none].include?(secondary)
            cleanup_hit=true
            if secondary.to_s.end_with?('throw')
              throw :cleanup_exit,:cleanup_value
            else
              raise secondary_error,cause:nil
            end
          end
        end
        source.call
      end
      service=GameRoomTournaments::ReadinessService.new(port:port,trusted_identity:'fixture:k03',directory:dir,context:reader)
      if target==:lock && primary
        port.hook=->(event,_) { injected=true; raise primary,cause:cause if event==:store_after }
      end
      target_file=->(f) do
        path=logical_path(f.path)
        target==:lock ? path.end_with?('/attempt.lock') : path.include?('/state.json.tmp-')
      end
      trace=TracePoint.new(:call,:return,:c_return) do |event|
        if event.self.equal?(service) && event.method_id==:boundary
          if event.event==:call
            cleanup=event.binding.local_variable_get(:cleanup)
            guards=0 if cleanup
          elsif event.event==:return
            cleanup=false
          end
        elsif event.event==:c_return && event.method_id==:open && event.self.equal?(File)
          file=event.return_value
          handles << file if file.is_a?(File) && logical_path(file.path).start_with?(logical_path(dir)+'/')
        elsif event.event==:c_return && event.self.is_a?(File) && handles.include?(event.self)
          if target==:temporary && event.method_id==:fsync && target_file.call(event.self) && !injected
            injected=true
            if primary
              raise primary,cause:cause
            else
              throw :original_exit,:temporary_interrupted
            end
          elsif cleanup && secondary==:callback_exception && event.method_id==:close && target_file.call(event.self) && !cleanup_hit
            cleanup_hit=true
            raise secondary_error,cause:nil
          end
        end
      end
      caught=nil; returned=nil
      invoke=-> do
        begin
          returned=catch(:cleanup_exit) { catch(:original_exit) { service.declare(request:F.request) } }
        rescue Exception => error
          caught=error
        end
      end
      begin
        trace.enable do
          if ambient
            begin
              raise ArgumentError,'Ambient nie należy do tej próby'
            rescue ArgumentError
              invoke.call
            end
          else
            invoke.call
          end
        end
        observations[:handles]=handles.map { |f| {path:f.path,closed:f.closed?} }
        observations[:cleanup_hit]=cleanup_hit
        observations[:caught_class]=caught && caught.class.name
        observations[:returned]=returned
        F.assert(secondary==:none ? !cleanup_hit : cleanup_hit,"Osiągnięta wybrana granica #{label}")
        F.assert(handles.any? { |f| target_file.call(f) },"Rzeczywisty zasób #{label}")
        F.assert(handles.all?(&:closed?),"Wszystkie własne uchwyty zamknięte #{label}")
        if primary
          F.assert(caught.equal?(primary) && caught.cause.equal?(cause) && caught.backtrace==['pierwotny-zasob:7'],"Obiekt/cause/backtrace primary #{label}")
        elsif secondary==:none
          F.assert(caught.nil?,"Ambient nie ożywił starego wyjątku #{label}")
          if target==:temporary
            F.assert(returned==:temporary_interrupted,"Własny throw bez primary #{label}")
          else
            F.assert(returned[:state]==:confirmed,"Zdrowa deklaracja #{label}")
          end
        elsif secondary.to_s.end_with?('throw')
          F.assert(caught.nil? && returned==:cleanup_value,"Throw bez własnego primary #{label}")
        else
          F.assert(caught.equal?(secondary_error) && caught.cause.nil? && caught.backtrace==['cleanup-zasob:9'],"Błąd cleanup bez własnego primary #{label}")
        end
        port.hook=nil
        anchors=Dir.glob(File.join(dir,'readiness-v1','*','*.intent'))
        F.assert(anchors.size==1,"Jedna trwała intencja #{label}")
        operation=JSON.parse(File.read(anchors.first))
        stores_before=port.calls.count(:store_before)
        next_service=F.service(dir,port,source)
        result=nil
        trace.enable { result=next_service.declare(request:F.request) }
        F.assert(handles.all?(&:closed?),"Readback zwolnił także nowe własne uchwyty #{label}")
        observations[:handles_after_readback]=handles.map { |f| {path:f.path,closed:f.closed?} }
        expected=target==:lock ? :confirmed : :unknown
        F.assert(result[:state]==expected && result[:operation_id]==operation['operation_id'],"Druga instancja uzgadnia ten sam UUID #{label}")
        F.assert(port.calls.count(:store_before)==stores_before,"Zero nowego store #{label}")
        observations[:readback]={state:result[:state],operation_id:result[:operation_id],stores_before:stores_before,stores_after:port.calls.count(:store_before)}
        failed=false
        observations
      ensure
        trace.disable
        if failed
          observations[:failed]=true
          observations[:handles_at_failure]=handles.map { |f| {path:f.path,closed:f.closed?} }
          File.write(File.join(ENV.fetch('ENTRY_EVIDENCE'),'resource-failure.json'),JSON.pretty_generate(observations),encoding:'UTF-8')
          handles.each { |f| f.close unless f.closed? }
        end
      end
    end
  end
end
results=[]
%i[lock temporary].each do |target|
  [NoMethodError,ReadinessCleanupFatal].each do |klass|
    %i[nil existing].each do |cause_kind|
      [false,true].each do |ambient|
        %i[pre_throw post_throw pre_exception post_exception callback_exception].each do |secondary|
          results << ReadinessCleanupResources.run(target:target,primary_class:klass,cause_kind:cause_kind,ambient:ambient,secondary:secondary)
        end
      end
    end
  end
  [false,true].each do |ambient|
    %i[pre_throw post_throw pre_exception post_exception callback_exception none].each do |secondary|
      results << ReadinessCleanupResources.run(target:target,primary_class:nil,cause_kind: :nil,ambient:ambient,secondary:secondary)
    end
  end
end
File.write(File.join(ENV.fetch('ENTRY_EVIDENCE'),'resource-observations.json'),JSON.pretty_generate(results),encoding:'UTF-8')
puts JSON.generate({passed:results.size,opis:'Własne lock/temp, primary, cause, ambient, throw i błędy cleanup; bez zamiany metod produkcji'})
