require "fileutils"
require "rbconfig"
require "rake/clean"
require "rake/testtask"

PROJECT_ROOT = __dir__
COVERAGE_DIR = File.join(PROJECT_ROOT, "coverage")
COVERAGE_BOOTSTRAP = File.join(PROJECT_ROOT, "test", "support", "coverage_bootstrap.rb")
COVERAGE_REPORT = File.join(PROJECT_ROOT, "test", "support", "coverage_report.rb")
TMP_DIR = File.join(PROJECT_ROOT, "tmp")

CLEAN.include(COVERAGE_DIR, TMP_DIR)

desc "Run all tests under test/"
Rake::TestTask.new(:test) do |t|
  t.pattern = "test/**/*_test.rb"
end

desc "Run all tests under test/ with line coverage"
task :coverage do
  original_coverage = ENV["WITSNET_COVERAGE"]
  original_project_root = ENV["WITSNET_PROJECT_ROOT"]
  original_rubyopt = ENV["RUBYOPT"]

  begin
    FileUtils.rm_rf(COVERAGE_DIR)
    FileUtils.mkdir_p(File.join(COVERAGE_DIR, "raw"))

    ENV["WITSNET_COVERAGE"] = "1"
    ENV["WITSNET_PROJECT_ROOT"] = PROJECT_ROOT
    ENV["RUBYOPT"] = [original_rubyopt, "-r#{COVERAGE_BOOTSTRAP}"].compact.join(" ")

    Rake::Task[:test].reenable
    Rake::Task[:test].invoke

    ENV["WITSNET_COVERAGE"] = original_coverage
    ENV["WITSNET_PROJECT_ROOT"] = original_project_root
    ENV["RUBYOPT"] = original_rubyopt

    system(RbConfig.ruby, COVERAGE_REPORT, PROJECT_ROOT, exception: true)
  ensure
    ENV["WITSNET_COVERAGE"] = original_coverage
    ENV["WITSNET_PROJECT_ROOT"] = original_project_root
    ENV["RUBYOPT"] = original_rubyopt
  end
end

task default: :coverage
