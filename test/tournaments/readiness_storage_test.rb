# encoding: UTF-8
require_relative '../support/tournament_readiness_faults'
F=TournamentReadinessFixture
J=GameRoomTournaments::ReadinessJournal
C=GameRoomTournaments::ReadinessContract
passed=[]; failures=[]
mutations={
  'duplikat root'=>->(bytes) { bytes.sub('{','{"version":1,') },
  'duplikat root inny'=>->(bytes) { bytes.sub('{','{"version":2,') },
  'duplikat escapowany'=>->(bytes) { bytes.sub('{','{"\\u0076ersion":1,') },
  'duplikat zagnieżdżony'=>->(bytes) { bytes.sub('"identity":{','"identity":{"account":"alice",') },
  'null'=>->(_) { 'null' },'tablica'=>->(_) { '[]' },'skalar'=>->(_) { '1' },
  'UTF-8'=>->(_) { "\xff".b },'limit'=>->(_) { ' '* (J::MAX_BYTES+1) },
  'duplikat operacji'=>->(bytes) { d=JSON.parse(bytes); d['records']<<F.copy(d['records'][0]); JSON.generate(d) },
  'dowód tablica'=>->(bytes) { d=JSON.parse(bytes); d['records'][0]['evidence']=[]; JSON.generate(d) },
  'dowód obcy autor'=>->(bytes) { d=JSON.parse(bytes); d['records'][0]['evidence']['result']['account']='bob'; JSON.generate(d) }
}
mutations.each do |name,change|
  F.isolated do |dir|
    port=F::Port.new; source=F::Context.new
    answer=F.service(dir,port,source).declare(request:F.request)
    path=Dir.glob(File.join(dir,'**','state.json')).fetch(0)
    healthy=File.binread(path); File.binwrite(path,change.call(healthy))
    result=F.service(dir,port,source).reconcile(scope:F.scope,match_ref:F.match_ref,operation_id:answer[:operation_id])
    F.assert(result[:reason]==:journal_corrupt,"#{name}: jawna odmowa uszkodzonego dziennika")
    F.assert(port.calls.count(:store_before)==1,'Korupcja nie daje ponowienia')
    File.binwrite(path,healthy)
    F.assert(F.service(dir,port,source).reconcile(scope:F.scope,match_ref:F.match_ref,operation_id:answer[:operation_id])[:state]==:confirmed,'Dokument bez mutacji rzeczywiście poprawny')
    passed << name
  rescue StandardError => error
    failures << [name,error.class.name,error.message]
  end
end
F.isolated do |dir|
  p=F::Port.new; source=F::Context.new
  answer=F.service(dir,p,source).declare(request:F.request)
  path=Dir.glob(File.join(dir,'**','state.json')).fetch(0)
  link=File.join(dir,'hardlink-test.json'); File.link(path,link)
  begin
    result=F.service(dir,p,source).reconcile(scope:F.scope,match_ref:F.match_ref,operation_id:answer[:operation_id])
    F.assert(result[:reason]==:journal_corrupt,'Rzeczywisty hardlink odrzucony')
    passed << 'hardlink'
  rescue StandardError => error
    failures << ['hardlink',error.class.name,error.message]
  ensure
    File.unlink(link)
  end
end
['//host/share','C:wzgledny'].each do |path|
  begin
    F.service(path,F::Port.new,F::Context.new)
    F.assert(false,'Niebezpieczna ścieżka musi być odrzucona')
  rescue C::Invalid => error
    F.assert(error.code==:invalid_directory,'UNC/drive-relative bez naprawiania')
    passed << path
  end
end
F.isolated do |dir|
  Dir.chdir(dir) do
    port=F::Port.new; source=F::Context.new
    service=F.service('./konto',port,source)
    Dir.mkdir('inne')
    Dir.chdir('inne') { F.assert(service.declare(request:F.request)[:state]==:confirmed,'Zapis po zmianie cwd') }
    F.assert(Dir.glob(File.join(dir,'konto','**','*.intent')).size==1 && Dir.children('inne').empty?,'Directory związane przed zmianą cwd')
    passed << 'zmiana cwd'
  end
end
# Symulowany Stat obejmuje gałąź symlink bez przywileju tworzenia dowiązań Windows.
F.isolated do |dir|
  fake=Struct.new(:symlink?,:directory?).new(true,true)
  io=->(cleanup:false,&block) do
    value=block.call
    block.source_location && value.is_a?(File::Stat) && value.directory? ? fake : value
  end
  store=J.new(directory:dir,scope:F.scope,match_ref:F.match_ref,account:'alice',io:io)
  begin
    store.with_attempt { F.assert(false,'Symlink nie może wejść w próbę') }
  rescue J::Corrupt
    passed << 'symlink: symulowany Stat'
  end
end
puts JSON.generate({passed:passed.size,cases:passed,failures:failures})
F.assert(failures.empty?,'Korupcja i niebezpieczne pliki odmawiają jawnie')
