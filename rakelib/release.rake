# frozen_string_literal: true

# Publishes the version in lib/zxing_ffi/version.rb from the tip of main (docs/release_checklist.md lists what comes
# before):
#
#   DRY_RUN=1 mise exec -- bundle exec rake release   # checks only: what is done, what is left, what is in the way
#   mise exec -- bundle exec rake release             # tag, wait for the gems, push them, GitHub release
#   NOTES=notes.md mise exec -- bundle exec rake release  # GitHub release notes (default: the CHANGELOG section)
#
# Once CI passed for the commit, it tags vX.Y.Z, waits for the Platform gems workflow that the tag starts (it rebuilds
# every gem without caches), downloads that run's zxing_ffi-gems artifact into pkg/vX.Y.Z/, checks it, pushes the six
# platform gems and then the ruby gem to RubyGems, and creates the GitHub release with the gems attached. Gems are
# never built locally. RubyGems requires MFA: the OTP is asked for once, and again whenever RubyGems rejects it (codes
# expire after 30 seconds). Every step skips what is already done, so running it again resumes after a failure (a job
# to re-run, an interrupted wait, a rejected code).
#
# This replaces Bundler's `rake release`, which pushes a locally built ruby gem and no platform gems.

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "rubygems/package"
require "shellwords"
require "tempfile"

module Release
  BRANCH = "main"
  CI_WORKFLOW = "ci.yml"
  GEMS_WORKFLOW = "platform-gems.yml"
  ARTIFACT = "zxing_ffi-gems"
  RUN_FIELDS = "databaseId,headSha,status,conclusion,url"

  module_function

  def version = PlatformGems.gem_version

  def tag = "v#{version}"

  def dir = File.join(PlatformGems::PKG, tag)

  # owner/name on GitHub, from the gemspec's homepage
  def repo = PlatformGems.gemspec.homepage.delete_prefix("https://github.com/")

  # File name => platform. Platform gems first: while the ruby gem is the only one of a version on RubyGems, every
  # platform installs it, without a bundled library.
  def gems
    PlatformGems::TARGETS.keys.to_h { |platform| ["zxing_ffi-#{version}-#{platform}.gem", platform] }
      .merge("zxing_ffi-#{version}.gem" => "ruby")
  end

  def assets = gems.keys + ["SHA256SUMS"]

  def call
    $stdout.sync = true
    status = check
    puts summary(status)
    abort "\nCannot release:\n#{status[:problems].map { |p| "- #{p}" }.join("\n")}" if status[:problems].any?
    return puts("\nDry run: nothing changed.") if ENV["DRY_RUN"]
    return puts("\nzxing_ffi #{version} is already released.") if released?(status)

    confirm
    wait_for_ci(status[:ci]) unless status[:ci]["status"] == "completed"
    tag!(status[:tagged])
    run = gems_run(status[:head])
    download(run)
    verify
    push
    github_release(run)
    puts "\nReleased zxing_ffi #{version}: https://rubygems.org/gems/zxing_ffi/versions/#{version}"
  rescue Interrupt
    abort "\nInterrupted: `rake release` resumes where it stopped."
  end

  # What is done and what stands in the way. Changes nothing (apart from fetching origin).
  def check
    problems = []
    problems << "gh is missing or not logged in (gh auth login)" unless capture("gh", "auth", "status")
    origin = capture("git", "remote", "get-url", "origin").to_s
    problems << "origin is #{origin}, not #{repo} on GitHub" unless origin.match?(%r{github\.com[:/]#{Regexp.escape(repo)}(\.git)?\z})
    run!("git", "fetch", "--quiet", "--tags", "origin", BRANCH)
    head = capture("git", "rev-parse", "HEAD")
    problems << "the working tree has changes" unless capture("git", "status", "--porcelain").to_s.empty?
    problems << "not on #{BRANCH}" unless capture("git", "branch", "--show-current") == BRANCH
    problems << "HEAD is not origin/#{BRANCH}" unless head == capture("git", "rev-parse", "origin/#{BRANCH}")
    problems << "CHANGELOG.md has no \"## #{version} (YYYY-MM-DD)\" section" unless changelog_section
    problems << "CHANGELOG.md still has an Unreleased section" if changelog.match?(/^## Unreleased/i)
    tagged = capture("git", "rev-parse", "--verify", "--quiet", "refs/tags/#{tag}^{commit}")
    problems << "#{tag} already tags #{tagged[0, 7]}, not HEAD" if tagged && tagged != head
    ci = latest_run(CI_WORKFLOW, commit: head, event: "push")
    if ci.nil?
      problems << "CI has not run for HEAD (#{head[0, 7]}) on GitHub"
    elsif ci["status"] == "completed" && ci["conclusion"] != "success"
      problems << "CI #{ci["conclusion"]} for HEAD: #{ci["url"]}"
    end
    {head: head, ci: ci, tagged: tagged, published: published, release: release_assets, problems: problems}
  end

  def summary(status)
    ci = status[:ci]
    published = status[:published].size
    release = status[:release]
    <<~TEXT

      zxing_ffi #{version} from #{status[:head][0, 7]} (#{capture("git", "log", "-1", "--format=%s")})
        CI:             #{ci ? "#{state(ci)}, #{ci["url"]}" : "no run"}
        Tag:            #{tag}, #{status[:tagged] ? "exists" : "to create and push"}
        RubyGems:       #{published} of #{gems.size} gems published
        GitHub release: #{release ? "exists, #{release.size} assets" : "to create"}
    TEXT
  end

  # "success", "failure", … once a workflow run completed, else "queued", "in_progress", …
  def state(run) = (run["status"] == "completed") ? run["conclusion"] : run["status"]

  def released?(status)
    status[:published].size == gems.size && status[:release] && (assets - status[:release]).empty?
  end

  def confirm
    print "\nThis pushes #{tag}, publishes #{gems.size} gems to RubyGems (a version can never be pushed again) " \
      "and creates the GitHub release.\nType #{version} to go on: "
    abort "Aborted." unless $stdin.gets.to_s.strip == version
  end

  def wait_for_ci(ci)
    ci = watch(ci, "CI")
    abort "CI #{ci["conclusion"]} for HEAD: #{ci["url"]}" unless ci["conclusion"] == "success"
  end

  def tag!(tagged)
    run!("git", "tag", "--annotate", tag, "--message", "zxing_ffi #{version}") unless tagged
    pushed = capture("git", "ls-remote", "--tags", "origin", "refs/tags/#{tag}").to_s
    run!("git", "push", "origin", "refs/tags/#{tag}") if pushed.empty?
  end

  # The newest Platform gems run of the tag, once it succeeded.
  def gems_run(head)
    run = nil
    60.times do # the run shows up a few seconds after the tag push
      break if (run = latest_run(GEMS_WORKFLOW, branch: tag, event: "push"))
      sleep 5
    end
    abort "No #{GEMS_WORKFLOW} run for #{tag} on GitHub." unless run
    abort "The #{tag} run built #{run["headSha"][0, 7]}, not HEAD (#{head[0, 7]})." unless run["headSha"] == head
    run = watch(run, "the Platform gems workflow (Ctrl-C is safe, `rake release` resumes)") unless run["status"] == "completed"
    return run if run["conclusion"] == "success"

    abort "The Platform gems run ended #{run["conclusion"]}: #{run["url"]}\n" \
      "Re-run it (gh run rerun #{run["databaseId"]} --failed --repo #{repo}), then `rake release` again."
  end

  def download(run)
    FileUtils.rm_rf(dir)
    run!("gh", "run", "download", run["databaseId"].to_s, "--repo", repo, "--name", ARTIFACT, "--dir", dir)
  end

  # The artifact holds exactly this version's gems and SHA256SUMS; each gem matches its sum and has the expected
  # name, version and platform, the ruby gem no vendor/ files, each platform gem one library and its notices, and all
  # of them the gemspec's other files.
  def verify
    found = Dir.children(dir).sort
    abort "#{dir} has #{found.join(", ")}; expected #{assets.sort.join(", ")}" unless found == assets.sort
    sums = File.readlines(File.join(dir, "SHA256SUMS"), chomp: true).to_h { |line| line.split.reverse }
    files = PlatformGems.gemspec.files.reject { |f| f.start_with?("vendor/") }.sort
    gems.each do |file, platform|
      path = File.join(dir, file)
      abort "#{file}: SHA-256 differs from SHA256SUMS" unless sums[file] == Digest::SHA256.file(path).hexdigest
      spec = Gem::Package.new(path).spec
      abort "#{file} is #{spec.full_name} (#{spec.platform})" unless [spec.name, spec.version.to_s, spec.platform.to_s] == ["zxing_ffi", version, platform]
      vendored = spec.files.grep(%r{\Avendor/})
      if platform == "ruby"
        abort "#{file} bundles #{vendored.join(", ")}" if vendored.any?
      else
        libraries = vendored.grep(%r{\Avendor/lib/libZXing})
        missing = PlatformGems::NOTICES.map { |notice| "vendor/lib/#{notice}" } - vendored
        abort "#{file}: vendor/lib has #{libraries.inspect}, lacks #{missing.inspect}" unless libraries.size == 1 && missing.empty?
      end
      abort "#{file}: its files differ from the gemspec's" unless (spec.files - vendored).sort == files
    end
    puts "#{dir}: #{gems.size} gems match SHA256SUMS and the gemspec"
  end

  def push
    published = self.published
    gems.each_key do |file|
      path = File.join(dir, file)
      if published.key?(file)
        abort "#{file} is on RubyGems with another SHA-256 (#{published[file]})" unless published[file] == Digest::SHA256.file(path).hexdigest
        puts "#{file}: already on RubyGems"
      else
        gem_push(path)
      end
    end
  end

  # `gem push` with the OTP in GEM_HOST_OTP_CODE and no terminal, so that a rejected code ends the command instead of
  # prompting; the code is then asked for again.
  def gem_push(path)
    loop do
      output, status = unbundled do
        Open3.capture2e({"GEM_HOST_OTP_CODE" => otp}, Gem.ruby, File.join(RbConfig::CONFIG["bindir"], "gem"), "push", path,
          stdin_data: "")
      end
      puts output
      return if status.success?
      return puts("#{File.basename(path)}: already on RubyGems") if output.include?("Repushing of gem versions is not allowed")
      abort "gem push #{File.basename(path)} failed." unless output.match?(/OTP|multi-?factor/i)

      @otp = nil
    end
  end

  def otp
    @otp ||= begin
      print "RubyGems OTP code: "
      code = $stdin.gets.to_s.strip
      abort "No OTP code." if code.empty?
      code
    end
  end

  def github_release(run)
    existing = release_assets
    if existing.nil?
      Tempfile.create(["release_notes", ".md"]) do |notes|
        notes.write(release_notes(run))
        notes.flush
        run!("gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--title", "zxing_ffi #{version}",
          "--notes-file", notes.path, *assets.map { |asset| File.join(dir, asset) })
      end
    elsif (missing = assets - existing).any?
      run!("gh", "release", "upload", tag, "--repo", repo, *missing.map { |asset| File.join(dir, asset) })
    else
      puts "GitHub release #{tag}: done"
    end
  end

  def release_notes(run)
    return File.read(ENV["NOTES"]) if ENV["NOTES"]

    <<~MARKDOWN
      #{changelog_section.strip}

      ## Assets

      The ruby gem, the six platform gems and `SHA256SUMS` attached below are the files published to RubyGems.org,
      built and verified by the [Platform gems](#{run["url"]}) workflow for this tag.
    MARKDOWN
  end

  def changelog = File.read(File.join(PlatformGems::ROOT, "CHANGELOG.md"))

  # The body of the "## <version> (YYYY-MM-DD)" section, or nil.
  def changelog_section
    changelog[/^## #{Regexp.escape(version)} \(\d{4}-\d{2}-\d{2}\)\n(.*?)(?=^## |\z)/m, 1]
  end

  # Gems of this version on RubyGems: file name => SHA-256.
  def published
    response = Net::HTTP.get_response(URI("https://rubygems.org/api/v1/versions/zxing_ffi.json"))
    return {} if response.is_a?(Net::HTTPNotFound)
    abort "RubyGems API: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).select { |v| v["number"] == version }.to_h do |v|
      [(v["platform"] == "ruby") ? "zxing_ffi-#{version}.gem" : "zxing_ffi-#{version}-#{v["platform"]}.gem", v["sha"]]
    end
  end

  # Asset names of the GitHub release, nil when there is none.
  def release_assets
    capture("gh", "release", "view", tag, "--repo", repo, "--json", "assets", "--jq", ".assets[].name")&.split("\n")
  end

  def latest_run(workflow, **filters)
    args = ["run", "list", "--repo", repo, "--workflow", workflow, "--limit", "1", "--json", RUN_FIELDS]
    filters.each { |name, value| args.push("--#{name}", value) }
    capture("gh", *args)&.then { |out| JSON.parse(out).first }
  end

  # Follows a workflow run until it finishes; returns its final state.
  def watch(run, what)
    puts "Waiting for #{what}: #{run["url"]}"
    system("gh", "run", "watch", run["databaseId"].to_s, "--repo", repo, "--interval", "30")
    JSON.parse(capture("gh", "run", "view", run["databaseId"].to_s, "--repo", repo, "--json", RUN_FIELDS) || abort("cannot read #{run["url"]}"))
  end

  def run!(*cmd)
    puts "$ #{Shellwords.join(cmd)}"
    system(*cmd, exception: true)
  end

  # Standard output of a command, stripped; nil when it fails or is missing.
  def capture(*cmd)
    out, status = Open3.capture2(*cmd, err: File::NULL)
    out.strip if status.success?
  rescue SystemCallError
    nil
  end

  def unbundled(&)
    defined?(Bundler) ? Bundler.with_unbundled_env(&) : yield
  end
end

Rake::Task["release"].clear if Rake::Task.task_defined?("release")

desc "Publish the version in version.rb from main: tag, wait for the Platform gems workflow, push its gems, GitHub " \
  "release (DRY_RUN=1: checks only)"
task :release do
  Release.call
end
