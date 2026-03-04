if ENV["WITSNET_COVERAGE"] == "1"
  require "coverage"
  require "fileutils"

  project_root = ENV.fetch("WITSNET_PROJECT_ROOT") do
    File.expand_path("../..", __dir__)
  end
  coverage_raw_dir = File.join(project_root, "coverage", "raw")

  FileUtils.mkdir_p(coverage_raw_dir)
  Coverage.start(lines: true)

  at_exit do
    coverage_file = File.join(coverage_raw_dir, "#{Process.pid}.marshal")
    File.binwrite(coverage_file, Marshal.dump(Coverage.result))
  end
end
