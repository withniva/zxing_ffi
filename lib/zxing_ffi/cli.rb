# frozen_string_literal: true

require "json"
require "optparse"

module ZXingFFI
  # The +zxing-scan+ command: scans files and prints one JSON object per barcode (JSON Lines).
  #
  # Exit codes: 0 at least one barcode found, 1 none found, 2 usage error, 3 processing error (any file failed).
  class CLI
    # Exit status: at least one barcode was found.
    EXIT_FOUND = 0
    # Exit status: no barcode was found.
    EXIT_NONE = 1
    # Exit status: invalid command line.
    EXIT_USAGE = 2
    # Exit status: at least one file could not be processed.
    EXIT_ERROR = 3

    # @param argv [Array<String>]
    # @param stdout [IO]
    # @param stderr [IO]
    # @param env [Hash] environment (for ZXING_PDF_PASSWORD)
    def initialize(argv, stdout: $stdout, stderr: $stderr, env: ENV)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @env = env
      @options = {}
      @text_only = false
      @diagnose = false
    end

    # @return [Integer] exit code
    def run
      files = parse!
      return diagnose if @diagnose

      if files.empty?
        @stderr.puts parser.banner
        return EXIT_USAGE
      end

      begin
        scanner = ZXingFFI::Scanner.new(**@options) # invalid options are a usage error, before any file is read
      rescue ArgumentError => e
        @stderr.puts "zxing-scan: #{e.message}"
        return EXIT_USAGE
      end

      found = false
      failed = false
      files.each do |file|
        scanner.scan(file).each do |barcode|
          found = true
          @stdout.puts(@text_only ? barcode.text : JSON.generate(record(file, barcode)))
        end
      rescue => e # one file failing (unreadable, no such page, …) must not stop the others
        failed = true
        @stderr.puts "zxing-scan: #{display(file)}: #{e.class.name.split("::").last}: #{e.message.lines.first&.strip}"
      end
      return EXIT_ERROR if failed

      found ? EXIT_FOUND : EXIT_NONE
    rescue OptionParser::ParseError => e
      @stderr.puts "zxing-scan: #{e.message}"
      @stderr.puts parser.banner
      EXIT_USAGE
    end

    # The JSON object for one barcode: +{file, page, format, text, bytes_b64?, content_type, position,
    # page_position, rotation, pass}+. +bytes_b64+ is present only for non-text content.
    # @return [Hash]
    def record(file, barcode)
      record = {file: display(file), page: barcode.page, format: barcode.format, text: barcode.text}
      record[:bytes_b64] = [barcode.bytes].pack("m0") unless barcode.content_type == :text
      record.merge(
        content_type: barcode.content_type,
        position: corners(barcode.position),
        page_position: barcode.page_position && corners(barcode.page_position),
        rotation: barcode.rotation,
        pass: barcode.pass
      )
    end

    private

    # File names are bytes on Linux: make them valid UTF-8 for JSON and messages.
    def display(file)
      file.to_s.dup.force_encoding(Encoding::UTF_8).scrub("�")
    end

    def corners(quad)
      quad.to_a.map { |point| [point.x, point.y] }
    end

    def diagnose
      @stdout.puts JSON.pretty_generate(ZXingFFI.diagnostics)
      EXIT_FOUND
    end

    def parse!
      files = parser.parse(@argv)
      password = @options[:password] || @env["ZXING_PDF_PASSWORD"]
      @options[:password] = password if password && !password.empty?
      files
    end

    def parser
      @parser ||= OptionParser.new do |o|
        o.banner = "Usage: zxing-scan [options] FILE..."
        o.version = ZXingFFI::VERSION
        o.on("-f", "--formats LIST", "comma-separated formats (default: all)") { |v| @options[:formats] = v.split(",").map(&:strip) }
        o.on("-e", "--effort LEVEL", %w[fast normal thorough], "fast|normal|thorough") { |v| @options[:effort] = v.to_sym }
        o.on("--stop MODE", "found|exhaustive|N") { |v| @options[:stop] = stop(v) }
        o.on("--dpi N", "render DPI for PDFs, or auto") { |v| @options[:dpi] = dpi(v) }
        o.on("-p", "--pages RANGE", "e.g. 1-3,7 (1-based)") { |v| @options[:pages] = pages(v) }
        o.on("--password PW", "PDF password (also ZXING_PDF_PASSWORD)") { |v| @options[:password] = v }
        o.on("-j", "--threads N", Integer, "pages scanned in parallel") { |v| @options[:threads] = v }
        o.on("--text-only", "print text only, one per line") { @text_only = true }
        o.on("--diagnose", "print diagnostics JSON and exit") { @diagnose = true }
      end
    end

    def stop(value)
      return value.to_sym if %w[found exhaustive].include?(value)
      return Integer(value, 10) if value.match?(/\A\d+\z/)

      raise OptionParser::InvalidArgument, "--stop #{value} (expected found, exhaustive or a number)"
    end

    def dpi(value)
      return :auto if value == "auto"
      return Integer(value, 10) if value.match?(/\A\d+\z/)

      raise OptionParser::InvalidArgument, "--dpi #{value} (expected a number or auto)"
    end

    # "1-3,7" → [1, 2, 3, 7]; "5-" → 5.. (every page from 5)
    def pages(value)
      return Range.new(Integer(Regexp.last_match(1), 10), nil) if value =~ /\A(\d+)-\z/

      value.split(",").flat_map do |token|
        case token.strip
        when /\A(\d+)\z/ then [Integer(Regexp.last_match(1), 10)]
        when /\A(\d+)-(\d+)\z/ then (Integer(Regexp.last_match(1), 10)..Integer(Regexp.last_match(2), 10)).to_a
        else raise OptionParser::InvalidArgument, "--pages #{value} (expected e.g. 1-3,7)"
        end
      end
    end
  end
end
