require_relative 'specifications'
require_relative '../game_room_localization'

module GameSurfaces
  using GameRoomLocalization::Translations

  class LayeredTileGrid < OrientedGridBox
    # Coordinates are available on demand, rather than repeated on every move.
    def cell_announcement(label); label; end
  end

  class LayeredTileBoard
    include ActionEmitter

    def initialize(spec, state: {})
      @spec = spec
      @layer = state_value(state, 'layer', 1).to_i
      @selected = state_value(state, 'epoch', nil) == spec.epoch ? state_value(state, 'selected', nil) : nil
      @control = LayeredTileGrid.new(1, 1, row_origin: :top, coordinate_first: true,
        header: spec.header.to_s, x: 0, y: 0, quiet: true)
      @control.on(:select) { choose_tile }
      refresh
      @control.set_logical_position(*clamped_position(state_value(state, 'x', 0), state_value(state, 'y', 0)))
    end

    def fields; [@control]; end

    def state
      {'layer'=>@layer, 'x'=>@control.x, 'y'=>@control.y, 'selected'=>@selected, 'epoch'=>@spec.epoch}
    end

    def reusable_for?(spec); spec.is_a?(LayeredTileBoardSpec); end

    def update_spec(spec)
      @selected = nil unless @spec.epoch == spec.epoch && spec.editable
      @spec = spec
      refresh
      self
    end

    def suppress_next_focus!(_index = 0); @control.suppress_next_focus!; end
    def cancel_pending_action?; !@selected.nil?; end

    def cancel_pending_action!
      return false unless cancel_pending_action?
      @selected = nil
      refresh
      speak(_('Tile selection cancelled.'))
      true
    end

    def handle_command(command, payload = {})
      case command.to_s
      when 'tile_layer'
        layer = payload.fetch('layer', payload[:layer]).to_i
        return false unless @spec.layers.any? { |item| item.number == layer }
        @layer = layer
        refresh
        speak(_('Layer %{layer}: %{tile}') % {layer: @layer, tile: @control.cell_label})
        true
      when 'tile_coordinates'
        speak(_('Layer %{layer}, row %{row}, column %{column}.') % {layer: @layer, row: @control.y + 1, column: @control.x + 1})
        true
      else
        false
      end
    end

    private

    def current_layer
      @spec.layers.find { |item| item.number == @layer } || @spec.layers.first
    end

    def clamped_position(x, y)
      [[[x.to_i, 0].max, @control.width - 1].min, [[y.to_i, 0].max, @control.height - 1].min]
    end

    def refresh
      layer = current_layer
      raise ArgumentError, 'A layered tile board needs nonempty rectangular layers' unless layer &&
        !layer.cells.empty? && !layer.cells.first.empty? && layer.cells.all? { |row| row.length == layer.cells.first.length }
      @layer = layer.number
      @cells = @spec.layers.flat_map { |item| item.cells.flatten }.compact.to_h { |cell| [cell.id.to_s, cell] }
      @selected = nil unless @spec.editable && @cells[@selected]&.selectable
      @control.resize(layer.cells.first.length, layer.cells.length)
      @control.set_cells(layer.cells.map do |row|
        row.map do |cell|
          next _('Empty position') unless cell
          cell.id.to_s == @selected ? _('%{tile}; selected') % {tile: cell.label} : cell.label
        end
      end)
    end

    def choose_tile
      return unless action_allowed? && @spec.editable
      cell = current_layer.cells.dig(@control.y, @control.x)
      unless cell&.selectable
        speak(cell ? cell.label : _('Empty position'))
        return
      end
      id = cell.id.to_s
      if @selected == id
        cancel_pending_action!
      elsif @selected.nil?
        @selected = id
        refresh
        speak(_('%{tile}; selected') % {tile: cell.label})
      elsif @cells.fetch(@selected).match_key != cell.match_key
        speak(_('These tiles do not match.'))
      else
        first, @selected = @selected, nil
        refresh
        emit_action('question', 'submit', {'question_id'=>@spec.question_id, 'answer'=>"#{first}:#{id}"})
      end
    end
  end
end
