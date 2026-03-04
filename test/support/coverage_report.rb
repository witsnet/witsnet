require "fileutils"

module CoverageReport
  module_function

  def merge!(base_result, extra_result)
    extra_result.each do |path, data|
      extra_lines = data.fetch(:lines).dup

      if base_result.key?(path)
        base_lines = base_result[path].fetch(:lines)
        base_result[path] = { lines: merge_line_hits(base_lines, extra_lines) }
      else
        base_result[path] = { lines: extra_lines }
      end
    end
  end

  def merge_line_hits(base_lines, extra_lines)
    max_length = [base_lines.length, extra_lines.length].max

    Array.new(max_length) do |index|
      base_hits = base_lines[index]
      extra_hits = extra_lines[index]

      if base_hits.nil? && extra_hits.nil?
        nil
      else
        base_hits.to_i + extra_hits.to_i
      end
    end
  end

  def format_summary(result, project_root)
    files = result
      .select { |path, _| path.start_with?(project_root + "/") }
      .reject { |path, _| path.include?("/test/") }
      .sort_by { |path, _| path }

    total_relevant = 0
    total_covered = 0
    file_summaries = files.map do |path, data|
      line_hits = data.fetch(:lines)
      relevant = line_hits.count { |hits| !hits.nil? }
      covered = line_hits.count { |hits| hits.to_i.positive? }
      percentage = relevant.zero? ? 100.0 : (covered * 100.0 / relevant)

      total_relevant += relevant
      total_covered += covered

      format(
        "%6.2f%% %4d/%-4d %s",
        percentage,
        covered,
        relevant,
        path.delete_prefix(project_root + "/")
      )
    end

    total_percentage = if total_relevant.zero?
      100.0
    else
      total_covered * 100.0 / total_relevant
    end

    [
      format("TOTAL %6.2f%% %4d/%d", total_percentage, total_covered, total_relevant),
      *file_summaries
    ].join("\n")
  end
end

project_root = File.expand_path(ARGV.fetch(0))
coverage_dir = File.join(project_root, "coverage")
coverage_file = File.join(coverage_dir, "coverage.txt")
raw_files = Dir[File.join(coverage_dir, "raw", "*.marshal")].sort

result = raw_files.each_with_object({}) do |path, combined|
  CoverageReport.merge!(combined, Marshal.load(File.binread(path)))
end

summary = CoverageReport.format_summary(result, project_root)

FileUtils.mkdir_p(coverage_dir)
File.write(coverage_file, summary + "\n")

puts
puts summary
puts
puts "Coverage report written to #{coverage_file}"
