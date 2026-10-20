# frozen_string_literal: true
require_relative 'mcr_patterns'

module GameRoomMahjong
  # Internal optimizer, NOT an accepted MCR score. Its caller must supply the
  # complete audited exclusion policy for the chosen rules edition. In
  # particular an empty/partial exclusions map cannot certify a winning hand.
  module MCRCombination
    module_function

    def select(candidates, exclusions:, scoped_exclusions: {})
      unless candidates.is_a?(Array) && candidates.length <= 64 && exclusions.is_a?(Hash) &&
          exclusions.all? { |id, others| valid_id?(id) && others.is_a?(Array) && others.all? { |other| valid_id?(other) } } &&
          scoped_exclusions.is_a?(Hash) && scoped_exclusions.all? { |id, others| valid_id?(id) && others.is_a?(Array) && others.all? { |other| valid_id?(other) } }
        raise ArgumentError, 'Invalid MCR combination input'
      end
      candidates.each do |candidate|
        unless candidate.is_a?(MCRPatterns::Candidate) && valid_id?(candidate.id) && candidate.id != 81 &&
            candidate.points.is_a?(Integer) && candidate.points.positive? && candidate.points <= 88 &&
            (candidate.points == MCRPatterns::POINTS.fetch(candidate.id - 1) || candidate.id == 57 && candidate.points == 6) &&
            valid_scope?(candidate.sets) && valid_scope?(candidate.scope)
          raise ArgumentError, 'Invalid MCR fan candidate'
        end
        if scoped_exclusions.key?(candidate.id) && candidate.scope.nil? ||
            scoped_exclusions.values.any? { |ids| ids.include?(candidate.id) } && candidate.sets.nil?
          raise ArgumentError, 'Missing scoped MCR implication metadata'
        end
      end
      # Exact duplicates must not manufacture additional points, while two
      # distinct Tile Hogs (sets=nil) remain separate candidates by occurrence.
      seen = {}
      ordered = candidates.each_with_index.filter_map do |candidate, index|
        key = [candidate.id, candidate.points, candidate.sets&.sort, candidate.scope&.sort]
        next if candidate.id != 64 && seen[key]
        seen[key] = true
        [candidate, index]
      end
        .sort_by { |candidate, index| [-candidate.points, candidate.id, candidate.sets || [], index] }
      suffix = Array.new(ordered.length + 1, 0)
      (ordered.length - 1).downto(0) { |index| suffix[index] = suffix[index + 1] + ordered[index][0].points }
      best, best_points = [], -1
      search = lambda do |index, chosen, points|
        return if points + suffix[index] <= best_points
        if index == ordered.length
          best, best_points = chosen.dup, points
          return
        end
        candidate = ordered[index][0]
        if compatible?(candidate, chosen, exclusions, scoped_exclusions)
          chosen << candidate
          search.call(index + 1, chosen, points + candidate.points)
          chosen.pop
        end
        search.call(index + 1, chosen, points)
      end
      search.call(0, [], 0)
      best.map { |candidate| MCRPatterns::Candidate.new(id: candidate.id, points: candidate.points,
        sets: candidate.sets&.dup&.freeze, scope: candidate.scope&.dup&.freeze).freeze }.freeze
    end

    def compatible?(candidate, chosen, exclusions, scoped_exclusions)
      return false if chosen.any? do |other|
        exclusions.fetch(candidate.id, []).include?(other.id) || exclusions.fetch(other.id, []).include?(candidate.id) ||
          scoped_conflict?(candidate, other, scoped_exclusions) || scoped_conflict?(other, candidate, scoped_exclusions) ||
          candidate.sets && other.sets && candidate.id == other.id && !(candidate.sets & other.sets).empty?
      end
      # Single-set facts (seat wind, prevailing wind, dragon pung) do not
      # consume a link between groups. For compound patterns the incidence
      # graph must be a forest: an extra fan may attach unused sets once, but
      # must not reuse an already-connected combination of sets.
      parent = (0...4).to_a
      root = ->(node) { node = parent[node] while parent[node] != node; node }
      (chosen + [candidate]).each do |fan|
        next unless fan.sets && fan.sets.length >= 2
        roots = fan.sets.map { |index| root.call(index) }
        return false unless roots.uniq.length == roots.length
        roots.drop(1).each { |node| parent[node] = roots.first }
      end
      true
    end
    private_class_method :compatible?

    def scoped_conflict?(higher, lower, policy)
      policy.fetch(higher.id, []).include?(lower.id) && (lower.sets - higher.scope).empty?
    end
    private_class_method :scoped_conflict?

    def valid_scope?(scope)
      scope.nil? || scope.is_a?(Array) && !scope.empty? && scope.uniq == scope &&
        scope.all? { |index| index.is_a?(Integer) && index.between?(0, 3) }
    end
    private_class_method :valid_scope?

    def valid_id?(id)
      id.is_a?(Integer) && id.between?(1, 81)
    end
    private_class_method :valid_id?
  end
end
