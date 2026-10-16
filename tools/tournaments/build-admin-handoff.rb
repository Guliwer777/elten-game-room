require 'json'
require 'digest'
require 'zip'
require_relative '../support/release_files'
require_relative '../../lib/tournaments/server_schema'

# Review bundle only. Does not install, register an application or upload data.
package,inventory,verification,output=ARGV
raise 'Usage: PACKAGE INVENTORY VERIFIED_REPORT NEW_ZIP' unless output
raise 'Output already exists' if File.exist?(output)
root=File.expand_path('../..',__dir__)
report=JSON.parse(File.read(verification))
raise 'Package not verified' unless report['state']=='PASS' && report['sha256']==Digest::SHA256.file(package).hexdigest
entries={}
%w[lib games content Audio locale LICENSES docs tools test].each do |folder|
  Dir.glob(File.join(root,folder,'**','*'),File::FNM_DOTMATCH).sort.each do |path|
    next unless File.file?(path)
    relative=path.delete_prefix(root+'/').tr('\\','/')
    next if relative.split('/').any?{|part|part.start_with?('.') || %w[__pycache__ node_modules tmp].include?(part)}
    next if %w[.pem .key .pyc .dll .exe].include?(File.extname(path).downcase)
    raise "Source escapes checkout: #{relative}" unless File.realpath(path).tr('\\','/').start_with?(root.tr('\\','/')+'/')
    entries['source/power-games/'+relative]=File.binread(path)
  end
end
%w[__app.rb manifest.json README.md LICENSE THIRD_PARTY_NOTICES.md AGENTS.md CONTRIBUTING.md].each do |name|
  path=File.join(root,name)
  entries['source/power-games/'+name]=File.binread(path) if File.file?(path)
end
entries['client/Power-Games-turnieje-admin.eltsetup']=File.binread(package)
entries['client/inventory.json']=File.binread(inventory)
entries['client/verification.json']=File.binread(verification)
entries['schema/tournament-tables.json']=JSON.pretty_generate({'tables'=>GameRoomTournaments::ServerSchema::PROPOSED_TABLES,
  'notifications'=>true,'coordination'=>'server_implementation_required','deployment'=>'official_owner_review_and_signature_required'})+"\n"
entries['README-ADMIN-PL.txt']=<<~TEXT
  PACZKA DLA ADMINISTRATORA POWER GAMES — 14 PAŹDZIERNIKA 2026

  client: czysty instalator do przeglądu, bez trybów lokalnych, sztucznych graczy
  i aplikacji testowej. Menu zawiera Listę turniejów, Utwórz turniej i Wstecz.
  Operacje są w menu kontekstowym, ponieważ kontrola niepotwierdzonego zapisu
  jest potrzebna również po wdrożeniu. Instalator jest niepodpisany.

  source/power-games: pełne źródła aplikacji wraz z częścią turniejową,
  tłumaczeniami, zasobami, narzędziami i testami. Testy/adaptacja deweloperska
  są wyłącznie materiałem źródłowym; nie ma ich w interfejsie instalatora.
  Kod gier pozostaje, ponieważ turnieje uruchamiają istniejące gry LiveSessions.
  schema: deklaracje trzech tabel turniejowych, gotowe do przeglądu właściciela.
  FILES.json: rozmiary i SHA256 wszystkich plików wewnątrz paczki.

  Klient wskazuje oficjalną aplikację Power Games:
  468f59c5-c9d7-47cd-80f1-1a6fbfd1aa80. Nie wskazuje aplikacji testowej guliwera
  i nie przenosi jej danych ani zgód. Bez wdrożonych tabel i praw oficjalnej
  aplikacji nie uruchomi się pełny dostęp turniejowy. Właściciel musi też
  podpisać oficjalną aktualizację; tej paczki nie należy traktować jako wydania.

  Gotowy jest kod klienta: tworzenie/zapisy/pary, planowanie i fazy, punktacja,
  tabele i wyniki, powiązania ze zwykłymi stołami, ręczne walkowery/anulowanie,
  zapis/wznowienie tego samego meczu oraz wcześniejszy status zakończenia.
  Zachowano 2/1/0, brak automatycznych walkowerów i kontrolę historii/operacji.

  NIE MA TU GOTOWEGO WDROŻONEGO SERWEROWEGO AUTOMATU.
  Skopiowanie źródeł Ruby klienta na serwer nie tworzy takiego procesu.
  Brakuje niezależnego koordynatora terminów, gotowości, zaproszeń i zajętości,
  atomowych rezerwacji/startu, trwałych identyfikatorów operacji oraz
  autorytatywnego zatwierdzania wyników, anulowania i wznowień. Istniejące
  stoły i ruchy pozostają w LiveSessions; nie trzeba zastępować ich drugim
  systemem stołów. Samo dodanie tabel nie uruchomi zaproszeń.

  Wymaga też przeglądu skalowanie: obecny bezpośredni odczyt wyników klienta
  ma budżet 64 spotkań, arytmetyka przyjmuje do 256 wyników, a dokument planu
  ma ograniczenie 256 KiB. Limit 128 uczestników w formularzu nie oznacza,
  że każdy format i pełne każdy-z-każdym dla 128 osób zmieści się w tych
  budżetach. Przed publicznym wdrożeniem trzeba zapewnić serwerowe projekcje
  wyników/paginację i uzgodnić ograniczenia. Nie wolno uznać częściowego
  odczytu ani brakującego wyniku za zakończenie turnieju.

  Instrukcja: source/power-games/docs/TOURNAMENT_ADMIN_HANDOFF.md.
  Pozostałe kontrakty: TOURNAMENT_SERVER_INTEGRATION.md,
  TOURNAMENT_PHASE_TRIAL.md, TOURNAMENT_FORFEIT_TRIAL.md,
  TOURNAMENT_SAVED_MATCH_TRIAL.md w tym samym katalogu.

  Nie ma kluczy, sesji MCP, prywatnego magazynu gracza ani historii Git.
  Nie wykonano instalacji, wdrożenia na serwerze ani wysłania na GitHub.
TEXT
manifest=entries.sort.map{|name,bytes|{'path'=>name,'bytes'=>bytes.bytesize,'sha256'=>Digest::SHA256.hexdigest(bytes)}}
entries['FILES.json']=JSON.pretty_generate(manifest)+"\n"
Zip::OutputStream.open(output){|zip|entries.sort.each{|name,bytes|zip.put_next_entry(name);zip.write(bytes)}}
Zip::File.open(output) do |zip|
  raise 'Archive entry set differs' unless zip.entries.map(&:name).sort==entries.keys.sort
  entries.each{|name,bytes|raise "Archive bytes differ: #{name}" unless zip.read(name).b==bytes.b}
end
result={'state'=>'PASS','files'=>entries.size,'bytes'=>File.size(output),'sha256'=>Digest::SHA256.file(output).hexdigest,
  'installer_sha256'=>report['sha256'],'contains_credentials'=>false,'server_deployed'=>false}
File.write(output+'.verification.json',JSON.pretty_generate(result)+"\n")
puts JSON.generate(result)
