require_relative "specifications"
require_relative "../game_room_localization"

module GameSurfaces
  using GameRoomLocalization::Translations




  class ReviewSurface
    include ActionEmitter

    def initialize(spec, state: {})
      @spec = spec
      raise ArgumentError, "a review surface requires an id" if @spec.id.to_s.empty?
      @items = @spec.items.to_a
      @decisions = @spec.decisions.to_a
      @read_only = @spec.read_only == true
      validate_items!
      @confirmed_decisions = confirmed_decisions
      @heading = build_heading if !@read_only
      @list = build_read_only_list(state) if @read_only || @items.empty?
      @controls = build_decision_controls(state) if !@read_only
      @submit = build_submit_button if !@read_only
    end

    def fields
      return [@list] if @read_only

      [@heading, @list].compact + @controls.to_a + [@submit]
    end

    def state
      return { "index" => @list.index.to_i } if @read_only

      {
        "decisions" => selected_decisions,
        "confirmed" => @confirmed_decisions.dup
      }
    end

    def suppress_next_focus!(field_index = 0)
      control = fields[field_index.to_i]
      control.suppress_next_focus! if control.respond_to?(:suppress_next_focus!)
    end

    # Emitting an action only asks the screen to submit it. Update this open
    # form after replay accepted the write, never after a denied or stale Enter.
    def action_accepted(selection)
      return if @read_only || selection['kind'] != 'review' || selection['action'] != 'change'
      return unless selection['review_id'].to_s == @spec.id.to_s
      item = @items.find { |candidate| candidate.id.to_s == selection['item_id'].to_s }
      return if item == nil
      value = selection['decision'].to_s
      return unless value.empty? || decisions_for(item).any? { |decision| decision.id.to_s == value }

      if value.empty?
        @confirmed_decisions.delete(item.id.to_s)
      else
        @confirmed_decisions[item.id.to_s] = value
      end
    end

    private

    def build_heading
      RefreshAwareListBox.new(
        [_('Use Tab to move between answers. Choose an assessment with the arrows and confirm it with Enter.')],
        header: @spec.header.to_s,
        index: 0,
        quiet: true
      )
    end

    def build_read_only_list(state)
      RefreshAwareListBox.new(
        @items.map { |item| item_label(item) },
        header: @spec.header.to_s,
        index: bounded_index(state_value(state, "index", 0)),
        quiet: true,
        empty_label: (@spec.empty_label || _("No answers to review")).to_s
      )
    end

    def build_decision_controls(state)
      remembered = state_value(state, "decisions", {})
      @items.map do |item|
        decisions = decisions_for(item)
        control = RefreshAwareListBox.new(
          [_('Not assessed')] + decisions.map { |decision| decision.label.to_s },
          header: [item_label(item), @spec.confirmation_hint.to_s].reject(&:empty?).join('. '),
          index: remembered_decision_index(remembered, item, decisions),
          quiet: true
        )
        control.on(:select) { emit_decision_confirmation(item, control, decisions) }
        control
      end
    end

    def build_submit_button
      button = Button.new((@spec.submit_label || _("Finish review")).to_s)
      button.on(:press) do
        if @confirmed_decisions.length != @items.length
          alert(_("Confirm an assessment for every answer before finishing."))
          next
        end
        emit_action(
          "review",
          "finish",
          {
            "review_id" => @spec.id.to_s,
            "decisions" => @confirmed_decisions.dup
          }
        )
      end
      button
    end

    def emit_decision_confirmation(item, control, decisions)
      selected = control.index.to_i - 1
      decision = decisions[selected] if selected >= 0
      value = decision == nil ? "" : decision.id.to_s
      previous = @confirmed_decisions[item.id.to_s].to_s
      return if value == previous

      emit_action(
        "review",
        "change",
        {
          "review_id" => @spec.id.to_s,
          "item_id" => item.id.to_s,
          "decision" => value,
          "_stay_open" => true
        }
      )
    end

    def selected_decisions
      result = {}
      @items.each_with_index do |item, index|
        decisions = decisions_for(item)
        selected = @controls[index].index.to_i - 1
        decision = decisions[selected] if selected >= 0
        result[item.id.to_s] = decision.id.to_s if decision != nil
      end
      result
    end

    def remembered_decision_index(remembered, item, decisions)
      value = remembered_value(remembered, item.id)
      value = item.decision if value == nil
      index = decisions.index { |decision| decision.id.to_s == value.to_s }
      index == nil ? 0 : index + 1
    end

    def confirmed_decisions
      # A rebuilt form receives authoritative decisions in its specification.
      # Remembered navigation must not override a newer accepted assessment.
      @items.each_with_object({}) do |item, values|
        value = item.decision.to_s
        allowed = decisions_for(item).any? { |decision| decision.id.to_s == value }
        values[item.id.to_s] = value if allowed
      end
    end

    def decisions_for(item)
      ids = item.decision_ids.to_a.map(&:to_s)
      return @decisions if ids.empty?

      @decisions.select { |decision| ids.include?(decision.id.to_s) }
    end

    def validate_items!
      ids = @items.map { |item| item.id.to_s }
      raise ArgumentError, "review item ids must not be empty" if ids.any?(&:empty?)
      raise ArgumentError, "review item ids must be unique" if ids.uniq.length != ids.length
      decision_ids = @decisions.map { |decision| decision.id.to_s }
      if !@read_only && decision_ids.empty?
        raise ArgumentError, "an editable review surface requires decisions"
      end
      raise ArgumentError, "review decision ids must not be empty" if decision_ids.any?(&:empty?)
      raise ArgumentError, "review decision ids must be unique" if decision_ids.uniq.length != decision_ids.length
      @items.each do |item|
        allowed_ids = item.decision_ids.to_a.map(&:to_s)
        next if allowed_ids.empty?
        if allowed_ids.uniq.length != allowed_ids.length || allowed_ids.any? { |id| !decision_ids.include?(id) }
          raise ArgumentError, "a review item contains unsupported decisions"
        end
      end
    end

    def item_label(item)
      text = if item.author.to_s.empty?
        _("%{category}: %{answer}") % { category: item.category.to_s, answer: item.answer.to_s }
      else
        _("%{category}; %{author}: %{answer}") % {
          category: item.category.to_s,
          author: item.author.to_s,
          answer: item.answer.to_s
        }
      end
      return text if item.status == nil || item.status.to_s.empty?

      _("%{answer}; status: %{status}") % { answer: text, status: item.status.to_s }
    end

    def bounded_index(index)
      return 0 if @items.empty?

      [[index.to_i, 0].max, @items.length - 1].min
    end



    def remembered_value(remembered, id)
      return nil if !remembered.respond_to?(:key?)
      return remembered[id.to_s] if remembered.key?(id.to_s)
      return remembered[id.to_sym] if id.respond_to?(:to_sym) && remembered.key?(id.to_sym)

      nil
    end
  end
end
