# encoding: UTF-8
require_relative '../support/ft2_c08_support'
include FT2C08Support
# Dokładne granice samego serializera, NIE naturalne plany ani retencja wykonana 2048 razy.
validators = {
  readiness: [65_536, 8192, 16, ->(v) { T::ReadinessContract.copy(v) }],
  coordination: [262_144, 16_384, 16, ->(v) { T::CoordinationContract.copy(v) }],
  state: [33_554_432, 524_288, 24, ->(v) { T::LocalFixedTeamExecutionStorage.allocate.copy(v) }]
}
rows = []
validators.each do |name, (bytes, nodes, depth, validate)|
  pairs = {
    bytes: ['x' * (bytes - 2), 'x' * (bytes - 1)],
    nodes: [Array.new(nodes - 1), Array.new(nodes)],
    depth: [depth.times.reduce(nil) { |v, _| [v] }, (depth + 1).times.reduce(nil) { |v, _| [v] }]
  }
  # UTF-8, cudzysłów, backslash i U+0001 są mierzone przez rzeczywisty JSON.generate.
  token = "ż\"\\\u0001"
  cost = JSON.generate(token).bytesize - 2
  escaped = token * ((bytes - 2) / cost)
  escaped += 'x' * (bytes - JSON.generate(escaped).bytesize)
  pairs[:escaped_utf8] = [escaped, escaped + 'x']
  pairs.each do |dimension, (good, bad)|
    actual = validate.call(good)
    assert_equal(good, actual)
    error = begin
      validate.call(bad)
      nil
    rescue T::Publication::Invalid => failure
      failure.code
    end
    assert_equal(:json_budget, error, "MAX+1 #{name}/#{dimension}")
    rows << {validator: name, dimension: dimension, good_json_bytes: JSON.generate(good).bytesize,
      bad_json_bytes: JSON.generate(bad).bytesize, bad: error, limit_bytes: bytes, limit_nodes: nodes, limit_depth: depth}
  end
end
oracle_file('ft2_c08_serializer.json', {classification: 'wyłącznie syntetyczne MAX/MAX+1', rows: rows})
puts 'GREEN C08: niezależne bytes/nodes/depth oraz escape UTF-8 na trzech rzeczywistych serializerach'
