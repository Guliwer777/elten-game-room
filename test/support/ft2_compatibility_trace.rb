# encoding: UTF-8
require 'json'

# Globalny TracePoint; brak podmiany metod produkcji i brak ograniczenia do wątku UI.
class FT2CompatibilityTrace
  WATCH = %i[request_match reconcile negotiate snapshot claim reserve lookup create_bind lookup_target
    create_room create start_session start_session_once start_game invite_user invite accept_invitation
    check join reconnect join_bound join_room join_table establish complete consent read_target append_record marker].freeze
  FORBIDDEN = %w[start_session start_session_once start_game invite_user invite accept_invitation
    join_room join_table establish complete consent].freeze
  attr_reader :rows, :workers

  def initialize
    @rows = []
    @workers = []
    @phase = nil
    @trace = TracePoint.new(:call) do |e|
      next unless @phase && WATCH.include?(e.method_id)
      row = {'phase' => @phase, 'method' => e.method_id.to_s, 'owner' => e.defined_class.to_s,
        'path' => e.path, 'line' => e.lineno, 'thread' => Thread.current.object_id,
        'stack' => caller_locations.map(&:to_s)}
      row['kind'] = e.binding.local_variable_get(:kind) if e.method_id == :append_record && e.binding.local_variable_defined?(:kind)
      @rows << row
    end
    @trace.enable(target_thread: nil)
  end

  def self.marker
    true
  end

  def during(name)
    raise 'Zagnieżdżony pomiar' if @phase
    @phase = name
    yield
  ensure
    @phase = nil
  end

  def forbidden(rows)
    rows.select { |r| FORBIDDEN.include?(r['method']) || r['kind'] == 'game_started' }
  end

  def check_empty(rows)
    bad = forbidden(rows)
    raise "RED_FT2A_C10: niedozwolone skutki: #{bad.inspect}" unless bad.empty?
    true
  end

  def worker(&operation)
    thread = Thread.new(&operation)
    thread.value
  ensure
    @workers << {id: thread.object_id, joined: !thread.alive?, alive: thread.alive?} if thread
  end

  def close
    @trace.disable
    raise 'Niedołączony własny worker' if @workers.any? { |row| row[:alive] || !row[:joined] }
  end
end
