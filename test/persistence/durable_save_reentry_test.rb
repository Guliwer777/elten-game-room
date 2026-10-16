# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('R1: ponowne wejście nie zastępuje receipt właściciela ani nie zwalnia uncertain') do |root, h, first, service, archive, command|
  second = DurableSaveFixture.intent(root)
  nested = DurableSaveFixture.use_case(h, archive)
  entered = false
  observations = []
  service.lost_reply = service.read_failure = true
  first.define_singleton_method(:for_source) do |**options|
    previous = super(**options)
    unless entered
      entered = true
      assert(previous.nil?, 'Punkt początkowy nie jest pusty')
      2.times do
        entries = Marshal.load(Marshal.dump(h.core.entries))
        error = caught { nested.call(**DurableSaveFixture.arguments(h), intent: second) }
        observations << {error: error, unchanged: h.core.entries == entries, uploads: service.state['uploads']}
      end
    end
    previous
  end
  error = save(command, h, first)
  operation = first.list.fetch(0)
  assert(operation['status'] == 'uncertain' && service.state['uploads'] == 1, 'Nie osiągnięto uncertain po jednym prawdziwym uploadzie')
  assert(frozen?(h), 'R1: przegrana próba zwolniła ochronę niepewnej intencji')
  assert(error.is_a?(Intent::Uncertain), "Wywołanie właściciela nie wykonało jedynego uploadu: #{error.inspect}")
  assert(observations.size == 2 && observations.all? { |o| o[:error].is_a?(Intent::Pending) && o[:unchanged] && o[:uploads] == 0 },
    'Ponowne wejście musi odmówić przed freeze, bez zwolnienia aktywnej blokady')
  boundaries = h.core.entries.select { |entry| entry.dig('packet', 'kind') == 'game_boundary' }
  assert(boundaries.size == 1 && boundaries.first['message_id'] == operation.dig('values', 'boundary', 'message_id'),
    'Receipt uploadu nie jest jedyną zachowaną granicą')
  bytes = File.binread(first.path)
  stack = Marshal.load(Marshal.dump(h.core.entries))
  assert(save(command, h, second).is_a?(Intent::Pending), 'Sekwencyjna próba nie odmówiła')
  assert(File.binread(first.path) == bytes && h.core.entries == stack && service.state['uploads'] == 1,
    'Późniejsza odmowa zmieniła rekord, receipt lub liczbę uploadów')
end
