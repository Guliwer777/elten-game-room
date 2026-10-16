# encoding: UTF-8
require_relative 'tournament_ft2b1_ui_probe'
module TournamentFT2B1Fix1
  F = TournamentFT2B1
  T = GameRoomTournaments
  module_function

  def selection(screen)
    form = screen.instance_variable_get(:@form)
    {selected_id: screen.controller.view[:selected_id], field: form.index,
      lists: form.fields.grep(ListBox).map { |f| {header: f.header, index: f.index, options: f.options.dup} },
      carets: form.fields.grep(EditBox).map { |f| [f.index, f.check] }}
  end

  def modal(driver, screen)
    value = nil
    driver.steps.unshift(['Match details', [27], ->(form) {
      edit = form.fields.first
      raise 'To nie jest natywny EditBox' unless edit.is_a?(EltenAPI::Controls::EditBox)
      value = {text: edit.text.dup, caret: edit.index, check: edit.check, field: form.index, control: edit}
    }])
    F.button(screen.instance_variable_get(:@form), 'View details').press
    raise 'Nie otwarto Szczegółów' unless value
    value
  end

  def modal_value(value)
    value.reject { |k, _| k == :control }
  end

  class Observer
    attr_reader :calls, :targets
    def initialize
      @calls = []
      @targets = [[T::LocalFixedTeamPlanBackend, :accept], [T::LocalFixedTeamReadinessPort, :store],
        [T::LocalFixedTeamCoordinationPort, :reserve], [T::LocalFixedTeamCoordinationPort, :create_bind],
        [GameRoomTransport, :create_room], [GameRoomTransport, :start_game]]
      @traces = @targets.map do |owner, name|
        method = owner.instance_method(name)
        trace = TracePoint.new(:call) do |event|
          @calls << {owner: owner.name, implementation: event.defined_class.name, method: event.method_id, thread: Thread.current.object_id,
            path: event.path, line: event.lineno}
        end
        trace.enable(target: method, target_thread: nil)
        trace
      end
    end
    def close
      @traces.each(&:disable)
    end
  end

  def positive(directory)
    fixture = F.fixture(directory)
    record = fixture[:record]
    %w[Ala Anna Bartek Beata].each do |actor|
      F.with_execution(fixture, actor) do |execution|
        F.select_execution(execution, record)
        result = execution.declare(availability: 'ready', expected_revision: 0)
        raise 'Brak rzeczywistego store' unless result[:state] == :confirmed
      end
    end
    result = nil
    F.with_execution(fixture, 'Ala', expires_at: record['evidence']['plan']['matches'].first['windows'].first['closes'] - 60) do |execution|
      F.select_execution(execution, record)
      result = execution.request_match
      raise 'Brak rzeczywistego reserve/create' unless result[:state] == :bound
    end
    # Dodatnia kontrola wejścia do realnej metody Start odmawia na argumentach;
    # nie uruchamia partii ani endpointu zwykłego stołu.
    transaction = T::LocalFixedTeamNativeProvider.new.open(state: {'creates' => [], 'cores' => []}, owner: 'Ala')
    transport = GameRoomTransport.new(transaction.program, **transaction.transport_options)
    start_error = nil
    begin
      transport.start_game
    rescue ArgumentError => error
      start_error = error
    ensure
      transport.close_local_view
      transaction.close
    end
    raise 'Brak odmowy Start bez argumentów' unless start_error
    {target: result[:target].to_h, start_refused: start_error.message, files: TournamentFT2B1UI.snapshot(fixture[:sandbox])}
  ensure
    fixture&.fetch(:program)&.finalize
    fixture&.fetch(:program)&.class&.app_runtime&.close
  end
end
