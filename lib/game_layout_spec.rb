module GameRoomLayout
  STANDARD_SECTIONS = [:status, :game, :chat, :history, :users].freeze

  class ViewSpec
    attr_reader :surface, :sections, :history_header, :history_empty_label,
      :trailing_parts, :restartable, :restart_label, :finished_text, :status_commands,
      :decision_focus_part, :decision_focus_key, :decision_focus_index

    def initialize(surface: nil, history_header: nil, history_empty_label: nil,
      trailing_parts: [], restartable: true, restart_label: nil, finished_text: nil, status_commands: [],
      decision_focus_part: nil, decision_focus_key: nil, decision_focus_index: nil)
      @decision_focus_part, @decision_focus_key = decision_focus_part, decision_focus_key
      @decision_focus_index = decision_focus_index
      @trailing_parts = trailing_parts.map(&:to_s).freeze
      @sections = @trailing_parts.empty? ? STANDARD_SECTIONS : (STANDARD_SECTIONS + [:game_actions]).freeze
      @restartable = restartable
      @restart_label = restart_label
      @finished_text = finished_text
      @status_commands = status_commands.to_a.freeze
      @surface = surface
      @history_header = history_header == nil ? nil : history_header.to_s
      @history_empty_label = history_empty_label == nil ? nil : history_empty_label.to_s
    end
  end

  Snapshot = Struct.new(
    :surface_state,
    :history_index,
    :users_index,
    :form_index,
    :focus_location,
    :surface_identity,
    :history_follows_tail,
    :chat_text,
    :chat_index,
    :chat_check,
    keyword_init: true
  )

end
