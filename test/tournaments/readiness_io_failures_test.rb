# encoding: UTF-8
require_relative '../support/tournament_readiness_faults'
F=TournamentReadinessFixture
C=GameRoomTournaments::ReadinessContract
passed=[]
['file.write(bytes)','file.flush','file.fsync'].each do |text|
  [1,2,3,4].each do |nth|
    [:before,:after].each do |moment|
      F.isolated do |dir|
        p=F::Port.new; source=F::Context.new
        service=F::FaultService.new(port:p,trusted_identity:'fixture:k03',directory:dir,context:source.method(:call))
        service.fault={text:text,nth:nth,when:moment}
        first=service.declare(request:F.request)
        F.assert(first[:state]==:unknown && first[:reason]==:local_uncertain,'Jawny błąd write/flush/fsync')
        count=p.calls.count(:store_before)
        next_result=F.service(dir,p,source).declare(request:F.request)
        F.assert(p.calls.count(:store_before)==count,'Błąd pliku nie daje resend')
        if text=='file.write(bytes)' && nth==1 && moment==:before
          F.assert(next_result[:reason]==:journal_corrupt,'Niepełny zatrzask odmawia, nie wymyśla nowego UUID')
        else
          F.assert(next_result[:operation_id]==first[:operation_id],'Pełny zapis zachował UUID')
        end
        passed << "#{text}/#{nth}/#{moment}"
      end
    end
  end
end
F.isolated do |dir|
  p=F::Port.new; source=F::Context.new
  active=false
  primary=NoMethodError.new('Pierwotny błąd portu'); primary.set_backtrace(['oryginal:3'])
  cause=ArgumentError.new('Oryginalna przyczyna')
  reader=-> { raise ArgumentError,'Wtórny błąd czytnika' if active; source.call }
  service=GameRoomTournaments::ReadinessService.new(port:p,trusted_identity:'fixture:k03',directory:dir,context:reader)
  p.hook=->(event,_) { if event==:store_after; active=true; raise primary,cause:cause; end }
  begin
    service.declare(request:F.request)
    F.assert(false,'Primary musi propagować')
  rescue NoMethodError => error
    F.assert(error.equal?(primary) && error.cause.equal?(cause) && error.backtrace==['oryginal:3'],'Czytnik i cleanup nie maskują primary/cause/backtrace')
  end
  p.hook=nil
  result=F.service(dir,p,source).declare(request:F.request)
  F.assert(result[:state]==:confirmed && p.calls.count(:store_before)==1,'Cleanup zwolnił blokadę mimo zepsutego czytnika')
  passed << 'ProgramError czytnika po własnym primary'
end
puts JSON.generate({passed:passed.size,cases:passed})
