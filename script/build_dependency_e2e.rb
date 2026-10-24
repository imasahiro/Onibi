# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
RECORDED_ENV_NAMES = %w[
  BUNDLE_FROZEN BUNDLE_GEMFILE BUNDLE_IGNORE_CONFIG BUNDLE_WITHOUT
  CC CFLAGS CPPFLAGS DEVELOPER_DIR HOME LANG LC_ALL LC_CTYPE LDFLAGS
  MACOSX_DEPLOYMENT_TARGET PATH RUBYLIB RUBYOPT SDKROOT TMPDIR GEM_HOME GEM_PATH
].freeze

options = { mode: nil, work_dir: nil, output: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby script/build_dependency_e2e.rb --mode MODE --work-dir DIR --output FILE"
  parser.on("--mode MODE", %w[baseline fixed]) { |value| options[:mode] = value }
  parser.on("--work-dir DIR") { |value| options[:work_dir] = value }
  parser.on("--output FILE") { |value| options[:output] = value }
end.parse!

abort "--mode, --work-dir, and --output are required" if options.values.any?(&:nil?)
abort "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?

work_dir = File.expand_path(options.fetch(:work_dir))
output_path = File.expand_path(options.fetch(:output))
abort "work directory already exists: #{work_dir}" if File.exist?(work_dir)
abort "output file already exists: #{output_path}" if File.exist?(output_path)

source_dir = File.join(ROOT, "ext/onibi")
build_dir = File.join(work_dir, "ext/onibi")
FileUtils.mkdir_p(build_dir)

source_paths = Dir.glob(File.join(source_dir, "*.{rb,c,h}")).sort
abort "no extension sources found in #{source_dir}" if source_paths.empty?

source_hashes = {}
source_paths.each do |path|
  name = File.basename(path)
  FileUtils.cp(path, File.join(build_dir, name))
  source_hashes["ext/onibi/#{name}"] = Digest::SHA256.file(path).hexdigest
end

execution_env = ENV.to_h
recorded_env = RECORDED_ENV_NAMES.filter_map do |name|
  [name, execution_env.fetch(name)] if execution_env.key?(name)
end.to_h.sort.to_h

report = {
  schema: "onibi-build-dependency-e2e-v1",
  mode: options.fetch(:mode),
  repository: ROOT,
  work_dir: work_dir,
  output: output_path,
  ruby: RbConfig.ruby,
  ruby_version: RUBY_VERSION,
  platform: RbConfig::CONFIG.fetch("arch"),
  object_extension: RbConfig::CONFIG.fetch("OBJEXT"),
  shared_extension: RbConfig::CONFIG.fetch("DLEXT"),
  source_hashes_before: source_hashes,
  environment: recorded_env,
  environment_capture: "Allowlist only; cwd is recorded per command; other inherited variables are omitted.",
  commands: [],
  observations: {},
  validation_errors: []
}

def run_command(report, env, cwd, argv)
  command_env = env.merge("PWD" => cwd)
  stdout, stderr, status = Open3.capture3(command_env, *argv, chdir: cwd)
  record = {
    argv: argv,
    cwd: cwd,
    stdout: stdout,
    stderr: stderr,
    exit_code: status.exitstatus,
    signal: status.termsig
  }
  report.fetch(:commands) << record
  record
end

def artifact_state(path)
  stat = File.stat(path)
  {
    path: path,
    size: stat.size,
    mtime_rational: stat.mtime.to_r.to_s,
    sha256: Digest::SHA256.file(path).hexdigest
  }
end

def object_path(build_dir, object_extension)
  pattern = File.join(build_dir, "**", "onibi.#{object_extension}")
  Dir.glob(pattern).first || raise("onibi object was not produced: #{pattern}")
end

def shared_object_path(build_dir, extension)
  pattern = File.join(build_dir, "**", "onibi.#{extension}")
  Dir.glob(pattern).first || raise("onibi extension was not produced: #{pattern}")
end

def compile_seen?(record, before_state, after_state)
  output = record.fetch(:stdout) + record.fetch(:stderr)
  compile_line = output.match?(/(?:^|\n)[^\n]*(?:-c\s+[^\n]*onibi\.c|compiling onibi\.c)/i)
  compile_line || before_state.fetch(:mtime_rational) != after_state.fetch(:mtime_rational)
end

def append_marker(path, marker)
  File.open(path, "a") { |file| file.write("\n/* #{marker} */\n") }
end

def set_source_mtime_after_object(source, object)
  target_time = Time.at(File.stat(object).mtime.to_i + 2)
  File.utime(target_time, target_time, source)
  delay = target_time.to_f - Time.now.to_f + 0.1
  sleep(delay) if delay.positive?
end

def require_load_path(build_dir, extension)
  shared_object = shared_object_path(build_dir, extension)
  candidate = File.expand_path(build_dir)
  loop do
    expected = File.join(candidate, "onibi", "onibi.#{extension}")
    return candidate if File.expand_path(expected) == shared_object

    parent = File.dirname(candidate)
    raise "cannot form require path for #{shared_object}" if parent == candidate

    candidate = parent
  end
end

begin
  configure = run_command(report, execution_env, build_dir, [RbConfig.ruby, "extconf.rb"])
  raise "extconf.rb failed with exit #{configure.fetch(:exit_code)}" unless configure.fetch(:exit_code).zero?

  initial_build = run_command(report, execution_env, build_dir, ["make", "V=1"])
  raise "initial make failed with exit #{initial_build.fetch(:exit_code)}" unless initial_build.fetch(:exit_code).zero?

  object = object_path(build_dir, RbConfig::CONFIG.fetch("OBJEXT"))
  report.fetch(:observations)[:initial_object] = artifact_state(object)
  report.fetch(:observations)[:initial_extension] = artifact_state(
    shared_object_path(build_dir, RbConfig::CONFIG.fetch("DLEXT"))
  )

  c_source = File.join(build_dir, "match.c")
  append_marker(c_source, "onibi build dependency E2E included C edit")
  set_source_mtime_after_object(c_source, object)
  report.fetch(:observations)[:included_c_source_after_edit] = artifact_state(c_source)
  before_c = artifact_state(object)
  c_build = run_command(report, execution_env, build_dir, ["make", "V=1"])
  raise "make after included C edit failed with exit #{c_build.fetch(:exit_code)}" unless c_build.fetch(:exit_code).zero?

  after_c = artifact_state(object)
  c_compiled = compile_seen?(c_build, before_c, after_c)
  report.fetch(:observations)[:included_c_edit] = {
    compiled: c_compiled,
    object_before: before_c,
    object_after: after_c,
    extension_after: artifact_state(shared_object_path(build_dir, RbConfig::CONFIG.fetch("DLEXT")))
  }

  header = File.join(build_dir, "onibi_ir.h")
  append_marker(header, "onibi build dependency E2E local header edit")
  set_source_mtime_after_object(header, object)
  report.fetch(:observations)[:header_after_edit] = artifact_state(header)
  before_header = artifact_state(object)
  header_build = run_command(report, execution_env, build_dir, ["make", "V=1"])
  raise "make after local header edit failed with exit #{header_build.fetch(:exit_code)}" unless header_build.fetch(:exit_code).zero?

  after_header = artifact_state(object)
  header_compiled = compile_seen?(header_build, before_header, after_header)
  report.fetch(:observations)[:local_header_edit] = {
    compiled: header_compiled,
    object_before: before_header,
    object_after: after_header,
    extension_after: artifact_state(shared_object_path(build_dir, RbConfig::CONFIG.fetch("DLEXT")))
  }

  before_unchanged = artifact_state(object)
  unchanged_build = run_command(report, execution_env, build_dir, ["make", "V=1"])
  raise "unchanged make failed with exit #{unchanged_build.fetch(:exit_code)}" unless unchanged_build.fetch(:exit_code).zero?

  after_unchanged = artifact_state(object)
  unchanged_compiled = compile_seen?(unchanged_build, before_unchanged, after_unchanged)
  report.fetch(:observations)[:unchanged_build] = {
    compiled: unchanged_compiled,
    object_before: before_unchanged,
    object_after: after_unchanged
  }

  load_path = require_load_path(build_dir, RbConfig::CONFIG.fetch("DLEXT"))
  smoke_source = <<~RUBY
    require "onibi"
    native = Onibi::Regexp.new("(ab)+").match("zzababx")
    abort "expected native MatchData" unless native.is_a?(Onibi::MatchData)
    mri = Regexp.new("(ab)+").match("zzababx")
    native_value = native && [native.begin(0), native.end(0), native.to_a]
    mri_value = mri && [mri.begin(0), mri.end(0), mri.to_a]
    abort "MRI mismatch: \#{native_value.inspect} != \#{mri_value.inspect}" unless native_value == mri_value
    puts JSON.generate(native: native_value, mri: mri_value)
  RUBY
  smoke = run_command(
    report,
    execution_env,
    work_dir,
    [RbConfig.ruby, "-I#{File.join(ROOT, "lib")}", "-I#{load_path}", "-rjson", "-e", smoke_source]
  )
  raise "extension MRI smoke check failed with exit #{smoke.fetch(:exit_code)}" unless smoke.fetch(:exit_code).zero?

  report.fetch(:observations)[:load_smoke] = {
    result: JSON.parse(smoke.fetch(:stdout)),
    extension: artifact_state(shared_object_path(build_dir, RbConfig::CONFIG.fetch("DLEXT")))
  }

  if options.fetch(:mode) == "baseline"
    report.fetch(:validation_errors) << "baseline did not reproduce the stale included-C object" if c_compiled
  else
    report.fetch(:validation_errors) << "included C edit did not compile" unless c_compiled
    report.fetch(:validation_errors) << "local header edit did not compile" unless header_compiled
    report.fetch(:validation_errors) << "unchanged build compiled the object" if unchanged_compiled
  end
rescue StandardError => e
  report[:error] = "#{e.class}: #{e.message}"
  report[:backtrace] = e.backtrace
ensure
  report[:source_hashes_after] = source_hashes.to_h do |relative, _hash|
    [relative, Digest::SHA256.file(File.join(ROOT, relative)).hexdigest]
  end
  report[:source_unchanged] = report[:source_hashes_before] == report[:source_hashes_after]
  report[:command_summary] = report.fetch(:commands).map do |command|
    { argv: command.fetch(:argv), cwd: command.fetch(:cwd), exit_code: command.fetch(:exit_code) }
  end
  FileUtils.mkdir_p(File.dirname(output_path))
  File.write(output_path, "#{JSON.pretty_generate(report)}\n")
end

unless report.fetch(:validation_errors).empty? && report[:error].nil? && report.fetch(:source_unchanged)
  warn "build dependency E2E failed; see #{output_path}"
  exit 1
end

puts "build dependency E2E passed; see #{output_path}"
