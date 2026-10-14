# encoding: UTF-8
require_relative '../support/tournament_readiness_faults'
F=TournamentReadinessFixture
passed=[]
[1,2,3].each do |nth|
  [:before,:after].each do |moment|
    F.isolated do |dir|
      port=F::Port.new; source=F::Context.new
      service=F::FaultService.new(port:port,trusted_identity:'fixture:k03',directory:dir,context:source.method(:call))
      service.fault={text:'File.rename(LocalFilesystem.native(temporary),LocalFilesystem.native(@path))',nth:nth,when:moment}
      first=service.declare(request:F.request)
      F.assert(first[:state]==:unknown && first[:reason]==:local_uncertain,'Niepewny rename jawny, bez pozornego potwierdzenia')
      anchors=Dir.glob(File.join(dir,'**','*.intent')).map { |p| JSON.parse(File.read(p)) }
      F.assert(anchors.size==1 && anchors[0]['operation_id']==first[:operation_id],'Pierwotny UUID zachowany również przed pierwszym rename')
      count=port.calls.count(:store_before)
      second=F.service(dir,port,source).declare(request:F.request)
      F.assert(port.calls.count(:store_before)==count,'Nowa instancja nie odsyła po niepewnym rename')
      F.assert(second[:operation_id]==first[:operation_id],'Readback ma pierwotny UUID')
      F.assert(second[:state]==(nth==3 ? :confirmed : :unknown),'Wynik zależy od rzeczywistego commit portu')
      passed << "rename #{nth}/#{moment}"
    end
  end
end
puts JSON.generate({passed:passed.size,cases:passed})
