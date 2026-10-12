require_relative '../../../games/krowa_support/sjp_definition_provider'

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
puts 'PASS SJP definition boundaries, missing definitions, comments, UTF-8, entities and cache'
