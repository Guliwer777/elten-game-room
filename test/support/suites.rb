module GameRoomTestSuites
  NAMES = %w[models transport ui native tooling integration].freeze
  ROOT = File.expand_path('../..', __dir__)
  ROOT_TESTS = %w[code_quality_test.rb game_imports_test.rb model_contract_test.rb].freeze
  FOLDER_SUITES = {
    'models' => 'models', 'transport' => 'transport', 'realtime' => 'transport',
    'session' => 'transport', 'ui' => 'ui', 'host' => 'native',
    'tooling' => 'tooling', 'localization' => 'tooling',
    'room' => 'integration', 'persistence' => 'integration',
    'statistics' => 'integration', 'integration' => 'integration',
    'quiz_contributions' => 'integration'
  }.freeze

  def self.paths(root: ROOT)
    Dir.glob('test/**/*_test.rb', base: root).sort.reject do |path|
      path.split('/')[1...-1].any? { |part| %w[support fixtures].include?(part) }
    end
  end

  # The filesystem records ownership; CI suites record the execution layer.
  # Native host contracts take precedence within every owner's directory.
  def self.classify(path, root: ROOT)
    text = File.read(File.join(root, path), encoding: 'UTF-8')
    return 'native' if text.match?(/EltenTestHost|support\/(?:host_source|binary_suite|native_host)/)
    folder = path.split('/')[1]
    return FOLDER_SUITES.fetch(folder) if FOLDER_SUITES.key?(folder)
    name = File.basename(path)
    return 'tooling' if name == 'code_quality_test.rb'
    return 'models' if name == 'model_contract_test.rb'
    if folder == 'games'
      return 'tooling' if text.match?(%r{require_relative ["'](?:\.\./)+tools/}) || name.match?(/translation|dictionary|export|generator|pack_builder/)
      return 'ui' if name.match?(/screen|surface|encoding|keyboard|shortcut|cursor|focus|navigation|presentation/)
      return 'models'
    end
    'integration'
  end

  def self.select(name, root: ROOT)
    raise ArgumentError, "Unknown suite #{name.inspect}; choose #{NAMES.join(', ')}" unless NAMES.include?(name)
    paths(root: root).select { |path| classify(path, root: root) == name }
  end
end
