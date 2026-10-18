# Native task mechanics only. Recovery, messages and access announcements stay
# with the caller that understands the operation's consequences.
class GameRoomNetworkTask
  def run(title, layout: nil, table_id: nil, ui: nil, client: nil, runner: nil, before_close: nil, chat_admission: false, move_admission: nil, &operation)
    @before_close = before_close
    if layout&.binding_generation.to_i > 0
      token = EltenAPI::Tasks::CancellationToken.new
      @pending = GameRoomUI::PendingOperation.new(layout: layout, table_id: table_id,
        session_id: layout.session_id, token: token, title: title, chat_admission: chat_admission,
        move_admission: move_admission,
        local_input: client.respond_to?(:local_input_during_operation?) ? client.method(:local_input_during_operation?) : nil)
      ui = @pending
    end
    options = { title: title, cancellable: true, show_after: 5.0 }
    options[:ui] = ui if ui != nil
    options[:cancellation_token] = token if token
    if client.respond_to?(:network_task_ui)
      token ||= EltenAPI::Tasks::CancellationToken.new
      @task_ui = client.network_task_ui(ui: ui, title: title, show_after: 5.0, cancellation_token: token)
      options[:ui], options[:cancellation_token] = @task_ui, token
    end
    EltenAPI::Tasks.run(**options) do |_progress, cancellation|
      cancellation.raise_if_cancelled!
      if runner
        runner.synchronize do
          cancellation.raise_if_cancelled!
          operation.call
        end
      else
        operation.call
      end
    end
  end

  # Caller invokes this after its recovery policy, including cancellation and
  # stale-view handling. Closing earlier would capture a different UI state.
  def close
    return if @closed
    @closed = true
    begin
      @task_ui&.close
    ensure
      begin
        @before_close&.call if @pending&.active?
      ensure
        @pending&.close
      end
    end
  end
end
