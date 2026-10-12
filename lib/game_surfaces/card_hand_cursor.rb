module GameSurfaces
  # Local presentation only. Raw hand order identifies the last received card;
  # displayed order identifies the predecessor after playing a card/packet.
  module CardHandCursor
    def self.snapshot(cards, raw_order, epoch, index)
      ids = cards.map { |card| card.id.to_s }
      { "ids" => ids, "raw_ids" => raw_order.to_a.map(&:to_s),
        "epoch" => epoch.to_s, "selected_id" => ids[index.to_i] }
    end

    def self.resolve(cards, raw_order, epoch, previous, index, sorted: false, select_drawn: true)
      previous = {} unless previous.is_a?(Hash)
      ids = cards.map { |card| card.id.to_s }
      raw = raw_order.to_a.map(&:to_s)
      old = previous["ids"].to_a
      same_hand = previous.key?("ids") && previous["epoch"] == epoch.to_s
      unless same_hand
        index = previous.key?("ids") ? 0 : [[index.to_i, 0].max, [cards.length - 1, 0].max].min
        return [cards, index, false]
      end

      added = raw - previous["raw_ids"].to_a
      unless sorted
        order = (old & ids) + added + (ids - old - added)
        by_id = cards.to_h { |card| [card.id.to_s, card] }
        cards = order.filter_map { |id| by_id[id] }
        ids = cards.map { |card| card.id.to_s }
      end
      selected = previous["selected_id"]
      target = added.reverse.find { |id| ids.include?(id) } if select_drawn
      target ||= selected if ids.include?(selected)
      if target == nil
        position = old.index(selected) || index.to_i
        target = old.take(position).reverse.find { |id| ids.include?(id) }
        target ||= old.drop(position + 1).find { |id| ids.include?(id) }
        target ||= ids.first
      end
      [cards, ids.index(target) || 0, target != nil && target != selected]
    end

    def self.navigation_index(card_ids, current_index, playable_ids, direction)
      allowed = playable_ids.to_a.each_with_object({}) { |id, result| result[id.to_s] = true }
      candidates = card_ids.to_a.each_index.select { |index| allowed[card_ids[index].to_s] }
      return nil if candidates.empty?

      current = current_index.to_i
      if direction.to_i < 0
        candidates.reverse.find { |index| index < current } || candidates.last
      else
        candidates.find { |index| index > current } || candidates.first
      end
    end

    # Pure decision shared by ordinary hands and packet hands. Their UI-specific
    # guards (open choice/prepared packet) remain with the owning surface.
    def self.playable_navigation(card_ids, current_index, payload)
      playable = payload['card_ids'] || payload[:card_ids]
      target = navigation_index(card_ids, current_index, playable, payload['direction'] || payload[:direction])
      return [nil, nil] if target == nil
      auto_id = (payload['auto_card_id'] || payload[:auto_card_id]).to_s
      action = payload['auto_action'] || payload[:auto_action]
      automatic = playable.to_a.map(&:to_s).uniq.length == 1 &&
        card_ids[target].to_s == auto_id && action.respond_to?(:to_h)
      [target, automatic ? action : nil]
    end
  end
end
