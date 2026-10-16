require_relative 'game_content'
require_relative 'game_room_localization'

# Definitions describe effective settings; normalized storage may omit defaults.
# These readers never expand or mutate stored options, which are also hashed
# into tournament plans and match bindings.
module GameRoomOptionValues
  using GameRoomLocalization::Translations
  module_function

  def read(definition, options)
    key = definition.key.to_s
    return options[key] if options.key?(key)
    return options[key.to_sym] if options.key?(key.to_sym)

    definition.default
  end

  # Check declared types before permissive game normalizers can coerce them.
  def valid?(definition, value)
    case definition.kind.to_sym
    when :boolean
      value == true || value == false
    when :integer
      value.is_a?(Integer)
    when :choice
      definition.choices.to_a.any? { |choice| choice.value.eql?(value) }
    when :multiple_choice
      value.is_a?(Integer) && value >= 0 && (value >> definition.choices.to_a.length) == 0
    when :multiple_values
      values = definition.choices.to_a.map(&:value)
      value.is_a?(Array) && value.all? { |item| item.is_a?(String) && values.include?(item) }
    else
      raise ArgumentError, "Unsupported game option type: #{definition.kind}"
    end
  end

  def selected_choices(definition, value)
    definition.choices.to_a.each_with_index.filter_map do |choice, index|
      selected = if definition.kind.to_sym == :multiple_values
        value.is_a?(Array) && value.include?(choice.value)
      else
        (value.to_i & (1 << index)) != 0
      end
      choice if selected
    end
  end

  def format(definition, value)
    result = case definition.kind.to_sym
    when :boolean
      value == true ? _("Yes") : _("No")
    when :choice
      choice = definition.choices.to_a.find { |item| item.value.eql?(value) }
      choice ? choice.label : value
    when :multiple_choice, :multiple_values
      selected = selected_choices(definition, value).map { |choice| text(choice.label) }
      selected.empty? ? _("None") : selected.join(', ')
    when :integer
      definition.summary_unit == :seconds ? (text(_("%{seconds} seconds")) % {seconds: value}) : value
    else
      raise ArgumentError, "Unsupported game option type: #{definition.kind}"
    end
    text(result)
  end

  # Full settings documents include disabled options and zero values, unlike
  # the shorter rulebook/table announcement. Visibility still belongs to games.
  def lines(game, options)
    game.effective_option_definitions(options).filter_map do |definition|
      next unless game.option_visible?(definition, options, normalize: false)

      text(definition.summary_label || definition.label) + ': ' + format(definition, read(definition, options))
    end
  end

  def text(value)
    GameRoomContent.utf8(value)
  end
  private_class_method :text
end
