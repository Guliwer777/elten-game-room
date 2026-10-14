# encoding: UTF-8
require_relative '../support/ft2_readiness_boundary_support'
B = FT2ReadinessBoundarySupport
F = B::F
C = B::C
J = B::J
directory, port, context, declared = B.prepare
before = B.map(directory)
rows = []
# Callback I/O jest wstrzykiwanym portem Journal, bez podmiany metod produkcji.
%i[lstat children binread].each do |point|
  [JSON::ParserError, EncodingError, NoMethodError, C::Invalid, C::Blocked, C::PortUnavailable].each do |type|
    [false, true].each do |with_cause|
      primary = type.new(type == C::Invalid || type == C::Blocked ? :reader_program_error : 'Błąd programu callbacka')
      cause = with_cause ? ArgumentError.new('Pierwotna przyczyna') : nil
      stack = ["czytnik-#{point}-#{type.name}.rb:7"]
      primary.set_backtrace(stack)
      inside = fired = armed = false
      visits = []; mutations = []; caught = nil
      trace = TracePoint.new(:call, :return, :c_return) do |event|
        if event.defined_class == J && event.method_id == :records
          inside = event.event == :call
        end
        if inside && event.event == :c_return && event.method_id == point && !fired
          value = event.return_value
          if point == :binread
            F.assert(value.is_a?(String) && JSON.parse(value).is_a?(Hash), 'Callback dopiero po zdrowym binread')
            visits << {point: point, bytes: value.bytesize, sha256: Digest::SHA256.hexdigest(value)}
          else
            visits << {point: point, returned_class: value.class.name}
          end
          armed = true
        end
        mutations << event.method_id if event.event == :call && event.defined_class == J && %i[claim observe resolve write_state write_file].include?(event.method_id)
      end
      io = ->(cleanup: false, &block) do
        value = block.call
        if armed && !cleanup
          armed = false; fired = true
          raise primary, cause: cause
        end
        value
      end
      store = B.journal(directory, io)
      begin
        trace.enable(target_thread: nil)
        store.with_attempt { store.records }
      rescue Exception => error
        caught = error
      ensure
        trace.disable
      end
      rows << {point: point, type: type.name, with_cause: with_cause, visits: visits, fired: fired,
        expected_primary_id: primary.object_id, actual_primary_id: caught&.object_id,
        same_primary: caught.equal?(primary), same_cause: caught && caught.cause.equal?(cause),
        expected_backtrace: stack, actual_backtrace: caught&.backtrace, actual_error: caught && {class: caught.class.name, message: caught.message},
        before: before, after: B.map(directory), mutations: mutations, locks: B.locks(directory)}
      F.assert(fired && !visits.empty?, 'Osiągnięta właściwa granica callbacka')
      F.assert(rows.last[:after] == before && mutations.empty? && rows.last[:locks].values.all?, 'Dysk exact, bez mutacji, lock wolny')
    end
  end
end
B.persist('callback-errors.json', {healthy_declaration: declared, rows: rows})
F.assert(rows.all? { |r| r[:same_primary] && r[:same_cause] && r[:actual_backtrace] == r[:expected_backtrace] },
  'RED_FT2_READINESS_BOUNDARY_CALLBACK: wyjątek portu I/O nie jest korupcją dokumentu')
puts JSON.generate({passed: rows.size, opis: 'Błędy callbacków po zdrowym lstat, children i binread zachowują exact primary/cause/backtrace'})
