# Release checklist

1. `mise exec -- bundle exec rake` is green locally (tests + standardrb), including `rake test:corpus` with the full
   fixture set, on the pinned zxing-cpp (3.1.1) and on Homebrew's build (`ZXING_LIB=/opt/homebrew/lib/libZXing.dylib`).
2. CI is green on GitHub: lint + gem build, ubuntu/macos × Ruby 3.3/3.4/4.0, min-zxing (3.1.0), all five loader
   variants.
3. `mise exec -- bundle exec rake bench OUT=docs/benchmark.md` re-run; zero false positives on the no-barcode fixtures
   at `:normal`.
4. `rake zxing:build` verified on a clean Ubuntu and macOS machine following the README; `zxing-scan --diagnose` shows
   the library, loaders and tools.
5. Version bumped in `lib/zxing_ffi/version.rb`, `CHANGELOG.md` dated, `yard stats` reviewed (public API documented).
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
8. Tag `vX.Y.Z` and push the tag: the workflow rebuilds every gem from scratch (no caches for tags). From that run,
   download the `zxing_ffi-gems` artifact (the ruby gem, six platform gems, `SHA256SUMS`), check the sums, and
   spot-check a platform gem with `gem specification <file> files` (`LICENSE.txt`, one `vendor/lib/libZXing.*` plus
   `NOTICE.txt`, `LICENSE-zxing-cpp.txt`, `LICENSE-libzueci.txt`).
9. `gem push` each of the seven gems (MFA required: `gem push --otp <code> <file>`; RubyGems trusted publishing from
   the tag workflow could replace this later), then the GitHub release with the changelog section.

