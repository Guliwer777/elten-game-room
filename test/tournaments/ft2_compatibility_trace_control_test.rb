# encoding: UTF-8
require_relative '../support/ft2_compatibility_boundary'
include FT2CompatibilityBoundary
trace = FT2CompatibilityTrace.new
begin
  result = positive_trace_control(trace)
  oracle_file('trace-positive.json', result)
  puts 'GREEN: rzeczywiste ordinary invite/Start obserwowane main+worker; negatywny oracle reaguje'
ensure
  trace.close
end
