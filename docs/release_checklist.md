# Release checklist

1. `mise exec -- bundle exec rake` is green locally (tests + standardrb), including `rake test:corpus` with the full
   fixture set, on the pinned zxing-cpp (3.1.1) and on Homebrew's build (`ZXING_LIB=/opt/homebrew/lib/libZXing.dylib`).
2. CI is green on GitHub: lint + gem build, ubuntu/macos × Ruby 3.3/3.4/4.0, min-zxing (3.1.0), all five loader
   variants.
3. `mise exec -- bundle exec rake bench OUT=docs/benchmark.md` re-run; zero false positives on the no-barcode fixtures
   at `:normal`.
4. `rake zxing:build` verified on a clean Ubuntu and macOS machine following the README; `zxing-scan --diagnose` shows
   the library, loaders and tools.
5. Version bumped in `lib/zxing_ffi/version.rb` (and in `Gemfile.lock`: `bundle install`), `CHANGELOG.md` dated,
   `yard stats` reviewed (public API documented).
6. `gem build zxing_ffi.gemspec` succeeds without warnings; inspect the file list (`LICENSE.txt` included; no
   fixtures, no vendor build).
7. Platform gems: the "Platform gems" workflow is green for the release commit (run it with workflow_dispatch; it
   also runs on PRs touching the build files). Every platform is built, checked (`check_library.sh`: glibc ≤ 2.28,
   only libc/libc++ dependencies, macOS minos 11.0 / 10.13) and installed from an index of all gems in clean
   containers without a system libZXing, where it must decode the PDF and PNG fixtures with its bundled library.
   x86_64-darwin is only smoke-tested under Rosetta: if an Intel Mac is at hand, `gem install` it there and run
   `zxing-scan --diagnose` (`"source": "bundled"`).
   To reproduce one locally: `rake gem:platform PLATFORM=<platform>` then `rake gem:verify PLATFORM=<platform>
   [IMAGE=…]` (Linux needs Docker; `DOCKER_RUN_ARGS="--cpus=4 --memory=6g"` caps it; `rake gem:platforms` lists the
   platforms). After a zxing-cpp upgrade, re-check the bundled library's licenses (packaging aborts if libzueci's
   notices changed) and the baselines above.
8. Merge the release commit into `main`, then publish from a clean, up-to-date `main` with
   `mise exec -- bundle exec rake release` (`DRY_RUN=1` first: it only checks and reports). It refuses to run unless
   CI passed for the commit and `CHANGELOG.md` has the dated section, and asks you to type the version before pushing
   anything. It tags `vX.Y.Z` and pushes the tag, so the Platform gems workflow rebuilds every gem from scratch (no
   caches for tags), and waits for that run. It then downloads the run's `zxing_ffi-gems` artifact (the ruby gem, six
   platform gems, `SHA256SUMS`) into `pkg/vX.Y.Z/` and checks the sums and every gem's name, version, platform and
   files: `LICENSE.txt`, and for platform gems one `vendor/lib/libZXing.*` plus `NOTICE.txt`, `LICENSE-zxing-cpp.txt`
   and `LICENSE-libzueci.txt`. It pushes the platform gems, then the ruby gem, asking for the RubyGems OTP (MFA is
   required; it asks again when a code is rejected). Last, it creates the GitHub release with the changelog section
   (`NOTES=file` replaces it) and the gems attached. Every step skips what is done, so after a failure (re-run failed
   jobs with `gh run rerun <id> --failed`) `rake release` resumes. Needs `gh` logged in and a RubyGems API key with
   push scope (`gem signin`).
9. Point consumers at the new version. RubyGems trusted publishing from the tag workflow could replace the OTP later.

