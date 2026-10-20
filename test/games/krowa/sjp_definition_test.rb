require_relative '../../../games/krowa_support/sjp_definition_provider'
require_relative '../../support/krowa_sjp_html'

def assert(condition, message)
  raise message unless condition
end

provider = GameRoomKrowa::SjpDefinitionProvider.new
heading = '<div><p><b>znaczenie:</b> <span><a href="/info">info</a> (2)</span></p></div>'
definition = '<p style="margin: .5em">1. Żółć &amp; żółcie;<br />2. &#x142;ódź &#243; &quot;tekst&quot;</p>'
comments = '<hr /><p>KOMENTARZE</p><div class="z"><p>(brak)</p></div><p><button>dodaj</button></p>'
assert(provider.parse((heading + definition + comments).b) == "1. Żółć & żółcie;\n2. łódź ó \"tekst\"", 'Lost real definition, Polish bytes, entities or paragraphs')

[
  heading + comments,
  heading + comments.sub('(brak)', 'Nie mylić z komentarzem użytkownika.'),
  heading + '<p> &nbsp; <br/> </p>' + comments,
  '<p>Brak takiego hasła.</p>' + comments,
  heading + '<hr/><p>KOMENTARZE</p><div><p>Definicja z komentarza</p></div><p>Inny przycisk</p>'
].each do |html|
  begin
    provider.parse(html)
    raise 'Missing definition consumed comments or the add-comment button'
  rescue GameRoomKrowa::DefinitionNotFoundError
  end
end

# A missing first homonym must not make the regexp cross its paragraph into
# comments. A later, real definition still uses the same bounded structure.
assert(provider.parse(heading + comments + heading + definition).start_with?('1. Żółć'), 'A later real definition was lost')

requests = []
html = heading + comments
cached = GameRoomKrowa::SjpDefinitionProvider.new(fetcher: ->(uri) { requests << uri.to_s; html })
begin
  cached.definition_for('POROZKŁADANIA')
  raise 'The missing definition was accepted'
rescue GameRoomKrowa::DefinitionNotFoundError
end
html = heading + '<p>prawidłowa definicja</p>'
assert(cached.definition_for('porozkładania') == 'prawidłowa definicja', 'A failed lookup was cached')
assert(cached.definition_for('POROZKŁADANIA') == 'prawidłowa definicja' && requests.size == 2, 'Successful lookup was not cached by normalized word')
assert(requests.all? { |uri| uri == 'https://sjp.pl/porozk%C5%82adania' }, 'Polish URL encoding changed')

def sjp_entry(lemma, forms, meaning)
  KrowaSjpHtml.entry(lemma, forms, meaning)
end

sadze_page = sjp_entry('saga', {'M' => %w[sadze sagą sagę sagi sago], 'N' => %w[sagach sagami sagom]}, 'Znaczenie sagi.') +
  sjp_entry('sadze', {'W' => %w[sadzach sadzami sadzom], 'f' => %w[sadzy]}, nil) +
  sjp_entry('sadz', {'O' => %w[sadza sadzem sadzowi sadzu], 's' => %w[sadze]}, 'Znaczenie sadza: skrzynia na ryby.') +
  sjp_entry('sadza', {'A' => %w[sadze], 'M' => %w[sadzą sadzę sadzo sadzy]}, 'Znaczenie sadzy: proszek.') + comments
requests = []
lookup = GameRoomKrowa::SjpDefinitionProvider.new(fetcher: ->(uri) { requests << uri.to_s; sadze_page.b })
expected = "sadz\nZnaczenie sadza: skrzynia na ryby.\n\nsadza\nZnaczenie sadzy: proszek."
assert(lookup.definition_for(' SADZE ') == expected, 'Nominative meanings were lost or the oblique saga meaning was selected')
assert(lookup.definition_for('sadze') == expected && requests.size == 1, 'The selected definitions were not cached')
assert(lookup.definition_for('SADZE'.b) == expected && requests.size == 1, 'Binary input changed cached definitions')

homonyms = sjp_entry('piec', {'F' => %w[piekł piekła]}, 'Czasownik.') +
  sjp_entry('piec', {'O' => %w[pieca piecem piecowi], 's' => %w[piece]}, 'Rzeczownik.')
assert(provider.parse(homonyms, word: 'piec') == "piec\nRzeczownik.", 'An exact verb homonym outranked the nominative noun')
plural = sjp_entry('pić', {'H' => %w[piły piła]}, 'Czasownik.') +
  sjp_entry('piła', {'M' => %w[piły pile piłę piłą piło], 'N' => %w[piłach piłami piłom]}, 'Rzeczownik.')
assert(provider.parse(plural, word: 'piły') == "piła\nRzeczownik.", 'A common feminine nominative plural was not preferred')
plural += sjp_entry('Piła', {'M' => %w[Pile Piłą Piłę Piło Piły]}, 'Miasto.')
assert(provider.parse(plural.b, word: 'PIŁY'.b) == "piła\nRzeczownik.", 'Binary uppercase input or a proper name changed the noun selection')
neuter = sjp_entry('pol', {'O' => %w[pola polem]}, 'Inny przypadek.') +
  sjp_entry('pole', {'U' => %w[pola polu polem], 'V' => %w[pól polach polami]}, 'Mianownik mnogi.')
assert(provider.parse(neuter, word: 'pola') == "pole\nMianownik mnogi.", 'Neuter nominative plural was confused with a masculine genitive')
neuter += sjp_entry('Pola', {'M' => %w[Polą Polę Poli Polo]}, 'Imię.')
assert(provider.parse(neuter, word: 'pola') == "pole\nMianownik mnogi.", 'A differently capitalized proper name was preferred')
assert(provider.parse(sjp_entry('menu', {}, 'Spis potraw.'), word: 'menu') == "menu\nSpis potraw.", 'An indeclinable headword was lost')

fallback = sjp_entry('sadza', {'A' => %w[sadze]}, nil) +
  sjp_entry('saga', {'M' => %w[sadze sagi]}, 'Pierwsze znaczenie.') +
  sjp_entry('inne', {'I' => %w[sadze]}, 'Drugie znaczenie.')
assert(provider.parse(fallback, word: 'sadze') == "saga\nPierwsze znaczenie.\n\ninne\nDrugie znaczenie.", 'Unavailable nominative definitions blocked the complete fallback')
duplicate = sjp_entry('sadza', {'A' => %w[sadze]}, 'To samo znaczenie.')
assert(provider.parse(duplicate + duplicate, word: 'sadze') == "sadza\nTo samo znaczenie.", 'Repeated SJP entries duplicated the displayed meaning')
different = sjp_entry('sadza', {'A' => %w[sadze]}, 'Inne znaczenie tego samego hasła.')
assert(provider.parse(duplicate + different, word: 'sadze') == "sadza\nTo samo znaczenie.\nInne znaczenie tego samego hasła.", 'Distinct meanings of one lemma were lost')
irregular = sjp_entry('dziecko', {'U' => %w[dziecka dzieckiem dziecku], '~' => %w[dzieci dzieciach]}, 'Znaczenie nieregularnego rzeczownika.')
assert(provider.parse(irregular, word: 'dzieci') == "dziecko\nZnaczenie nieregularnego rzeczownika.", 'An unclassified irregular form lost its fallback meaning')
begin
  provider.parse(sjp_entry('sadze', {'W' => %w[sadzach]}, nil) + comments, word: 'sadze')
  raise 'An entry separator was presented as a definition'
rescue GameRoomKrowa::DefinitionNotFoundError
end

# Verify mixed SJP flag rows by their grammatical result, not row membership.
[
  ['sagi', 'saga', {'M' => %w[sadze sagi], 'N' => %w[sagach]}, true],
  ['sadze', 'saga', {'M' => %w[sadze sagi], 'N' => %w[sagach]}, false],
  ['sadzy', 'sadza', {'A' => %w[sadze], 'M' => %w[sadzy]}, false],
  ['kolegi', 'kolega', {'M' => %w[kolegi], 'q' => %w[koledzy]}, false],
  ['kości', 'kość', {'M' => %w[kości kością], 'N' => %w[kościach]}, true],
  ['matce', 'matka', {'M' => %w[matki matce], 'N' => %w[matkach]}, false],
  ['wiedzy', 'wiedza', {'M' => %w[wiedzy wiedzą]}, false],
  ['dziecka', 'dziecko', {'U' => %w[dziecka dziecku]}, false],
  ['centra', 'centrum', {'V' => %w[centra centrów centrach]}, true],
  ['centrów', 'centrum', {'V' => %w[centra centrów centrach]}, false],
  ['ramiona', 'ramię', {'V' => %w[ramiona ramion ramionach]}, true],
  ['królowe', 'królowa', {'K' => %w[królowe królowej królowych]}, true],
  ['królowych', 'królowa', {'K' => %w[królowe królowej królowych]}, false],
  ['gołębie', 'gołąb', {'u' => %w[gołębie gołębi gołębiom]}, true],
  ['gołębi', 'gołąb', {'u' => %w[gołębie gołębi gołębiom]}, false]
].each do |word, lemma, forms, expected_nominative|
  actual = GameRoomKrowa::SjpNounForms.nominative?(word, lemma, forms)
  assert(actual == expected_nominative, "Wrong SJP noun case classification: #{word} / #{lemma}")
end
puts 'PASS SJP definition boundaries, missing definitions, comments, UTF-8, entities and cache'
puts 'PASS SJP nominative nouns, named meanings, homonyms and complete fallback'
