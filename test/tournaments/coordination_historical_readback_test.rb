# encoding: UTF-8
require_relative '../support/tournament_coordination_fix_cases'
T=TournamentCoordinationFixCases
cases={}
%i[request_match reconcile].each do |method|
  %i[withdrawn later invalidated expired window_end].each do |mode|
    %i[local successor].each do |owner|
      cases["create-#{method}-#{mode}-#{owner}"]=->(dir,data) do
        local=File.join(dir,'alice')
        request,original,context,first=T.stored(local)
        receipt=original.copy(original.operations['create_bind'])
        T.lifecycle(original,mode)
        port=original
        if owner==:successor
          port=TournamentCoordinationPort.new(request,account:'bob')
          port.operations.merge!(original.copy(original.operations))
          port.ready=original.copy(original.ready);port.grant=original.copy(original.grant);port.time=original.time
          context=T::F.context(account:'bob');local=File.join(dir,'bob')
        else
          # Brak shared wymusza odczyt lokalnego pierwotnego opid, nie ścieżkę następcy.
          port.hook=->(event,value) { value['shared']={} if event==:snapshot }
        end
        before=T.mutations(port);lookups=port.calls.count(:lookup)
        service=T.service(port,local,context)
        answer=service.public_send(method,request:request)
        again=service.public_send(method,request:request)
        data.merge!(first:T.result(first),answer:T.result(answer),again:T.result(again),calls:port.calls)
        T.bound(answer,receipt);T.bound(again,receipt)
        T.assert(T.mutations(port)==before && port.calls.count(:lookup)==lookups+2,'Wyłącznie readback, bez nowych mutacji')
        T.assert(T.mutations(original)==[1,1],'Jeden pierwotny reserve/create')
        T.assert(receipt['operation']['actor']=='alice' && receipt['result']['creator_account']=='alice','Następca nie staje się właścicielem')
        document=JSON.parse(File.binread(Dir.glob(File.join(local,'coordination-v1','*.json')).fetch(0)))
        record=document['operations'].find { |r| r['operation']['kind']=='create_bind' }
        T.assert(record['status']=='confirmed' && record['evidence'].eql?(receipt),'Pełny trwały exact receipt')
      end
    end
  end
  %i[withdrawn later invalidated expired window_end].each do |mode|
    cases["reserve-#{method}-#{mode}"]=->(dir,data) do
      request,port,context,first=T.stored(dir,'reserve')
      T.lifecycle(port,mode);lookups=port.calls.count(:lookup)
      answer=T.service(port,dir,context).public_send(method,request:request)
      data.merge!(answer:T.result(answer),calls:port.calls)
      T.assert(answer[:operation_id]==first[:operation_id] && port.calls.count(:lookup)>lookups,'Historyczny reserve odczytany po pierwotnym ID')
      T.assert(answer[:state]==(method==:reconcile ? :reserved : :blocked),'Read-only reserve nie upoważnia do nowego create')
      T.assert(T.mutations(port)==[1,0],'Brak ponownego reserve i nowego create bez świeżej kwalifikacji')
    end
  end
end
%i[withdrawn later].each do |mode|
  cases["fresh-reserve-#{mode}"]=->(dir,data) do
    request=T::F.request;port=TournamentCoordinationPort.new(request);T.lifecycle(port,mode)
    answer=T.service(port,dir).request_match(request:request)
    data[:answer]=T.result(answer)
    T.assert(answer[:reason]==:not_all_ready && T.mutations(port)==[0,0],'Bez starej operacji withdrawn/later blokuje nowy reserve/create')
    T.assert(Dir.glob(File.join(dir,'**','*.json')).empty?,'Brak nowej intencji')
  end
  cases["withdraw-between-reserve-create-#{mode}"]=->(dir,data) do
    request=T::F.request;port=TournamentCoordinationPort.new(request)
    port.hook=->(event,_) { T.lifecycle(port,mode) if event==:reserve_after }
    answer=T.service(port,dir).request_match(request:request)
    data[:answer]=T.result(answer)
    T.assert(answer[:reason]==:not_all_ready && T.mutations(port)==[1,0],'Świeża bramka gotowości przed nowym create')
  end
end
%i[request_match reconcile].each do |method|
  %w[authorized_account scope seal_status request ready].each do |field|
    cases["deny-snapshot-#{method}-#{field}"]=->(dir,data) do
      request,port,context,_=T.stored(dir);T.lifecycle(port,:withdrawn)
      before=port.calls.count(:lookup)
      port.hook=->(event,value) { value[field]=nil if event==:snapshot }
      answer=T.service(port,dir,context).public_send(method,request:request)
      data[:answer]=T.result(answer)
      T.assert(answer[:state]==:blocked && answer[:binding].nil? && port.calls.count(:lookup)==before,'Brak autoryzowanego snapshotu: zero historycznego lookup')
      T.assert(T.mutations(port)==[1,1],'Odmowa nie mutuje')
    end
  end
  %w[seal_id plan_id match_id leg execution_generation players options].each do |field|
    cases["deny-spec-#{method}-#{field}"]=->(dir,data) do
      request,port,context,_=T.stored(dir);T.lifecycle(port,:withdrawn)
      before=port.calls.count(:lookup)
      port.hook=->(event,value) do
        if event==:snapshot
          spec=value['request']
          case field
          when 'leg' then spec[field]=2
          when 'players' then spec[field].reverse!
          when 'options' then spec[field]['draw_responses']=false
          else spec[field]='other'
          end
        end
      end
      answer=T.service(port,dir,context).public_send(method,request:request)
      data[:answer]=T.result(answer)
      T.assert(answer[:state]==:blocked && port.calls.count(:lookup)==before && T.mutations(port)==[1,1],'Exact plan/spec przed odczytem')
    end
  end
  %w[scope operation_id request_digest operation result].each do |field|
    cases["deny-readback-#{method}-#{field}"]=->(dir,data) do
      request,port,context,_=T.stored(dir);T.lifecycle(port,:withdrawn)
      before=port.calls.count(:lookup)
      port.hook=->(event,value) do
        if event==:lookup
          case field
          when 'scope' then value[field]['tournament_id']='other'
          when 'operation' then value[field]['request']['leg']=2
          when 'result' then value[field]['table_id']=42.0
          else value[field]='mismatch'
          end
        end
      end
      answer=T.service(port,dir,context).public_send(method,request:request)
      data[:answer]=T.result(answer)
      T.assert(port.calls.count(:lookup)==before+1 && answer[:state]==:blocked && answer[:binding].nil?,'Odmowa na właściwej granicy exact readback')
      T.assert(T.mutations(port)==[1,1],'Brak mutacji po mismatch')
    end
  end
  %w[account backend_identity runtime generation epoch cancelled grant_epoch].each do |field|
    %i[snapshot lookup].each do |boundary|
      cases["deny-context-#{method}-#{boundary}-#{field}"]=->(dir,data) do
        request,port,context,_=T.stored(dir);T.lifecycle(port,:withdrawn)
        port.hook=->(event,_) do
          if event==boundary
            context[field]=field=='cancelled' ? true : field.include?('epoch') ? 3 : 'changed'
          end
        end
        service=T.service(port,dir,context)
        answer=service.public_send(method,request:request)
        count=port.calls.length
        context.replace(T::F.context);port.hook=nil
        again=service.public_send(method,request:request)
        data.merge!(answer:T.result(answer),again:T.result(again))
        T.assert(answer[:state]==:blocked && answer[:binding].nil? && again[:reason]==:context_changed,'Kontekst/ABA zatrzaskuje odmowę przed i po I/O')
        T.assert(port.calls.length==count && T.mutations(port)==[1,1],'Powrót konta nie przywraca starego callbacku')
      end
    end
  end
end
cases['successor-reserve-no-owner']=->(dir,data) do
  request,original,_,first=T.stored(File.join(dir,'alice'),'reserve')
  port=TournamentCoordinationPort.new(request,account:'bob')
  port.operations.merge!(original.copy(original.operations));port.grant=original.copy(original.grant)
  answer=T.service(port,File.join(dir,'bob'),T::F.context(account:'bob')).request_match(request:request)
  data[:answer]=T.result(answer)
  T.assert(answer[:reason]==:takeover_required && answer[:operation_id]==first[:operation_id] && T.mutations(port)==[0,0],'Historyczny odczyt nie nadaje grantu/owner następcy')
end
T.run(cases,'historical')
