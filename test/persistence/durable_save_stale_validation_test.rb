# encoding: UTF-8
require_relative '../support/durable_save_cases'
include DurableSaveCases

scenario('R1: stary nil, reentry i późniejszy błąd walidacji PRZED prepare') do |root, h, a, service, archive, command|
  b = DurableSaveFixture.intent(root)
  entered, nested_error, rejected_without_boundary = false, nil, nil
  original = ArgumentError.new('Definitywna odmowa walidacji przed prepare')
  a.define_singleton_method(:for_source) do |**args|
    previous = super(**args)
    unless entered
      entered = true
      assert(previous.nil?, 'Niepusty prawdziwy odczyt')
      before = Marshal.load(Marshal.dump(h.core.entries))
      service.lost_reply = service.read_failure = true
      nested_error = save(command, h, b)
      service.lost_reply = service.read_failure = false
      rejected_without_boundary = (before == h.core.entries)
      archive.define_singleton_method(:validate) do |row, game:|
        super(row, game: game)
        raise original
      end
    end
    previous
  end
  error = save(command, h, a)
  assert(error.equal?(original), 'Błąd walidacji nie dotarł do wywołującego')
  assert(nested_error.is_a?(Intent::Pending) && rejected_without_boundary, 'R1: drugi zapis wszedł między odczyt a freeze')
  assert(service.state['uploads'] == 0 && a.list.empty? && !frozen?(h) && !h.core.closed,
    'R1: walidacja przed prepare pozostawiła wysłane archiwum bez ochrony')
  boundaries = h.core.entries.select { |entry| entry.dig('packet', 'kind') == 'game_boundary' }
  assert(boundaries.map { |entry| entry.dig('packet', 'data', 'frozen') } == [true, false], 'Nie oddano wyłącznie własnej granicy')
end
