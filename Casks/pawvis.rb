# Homebrew cask scaffold for Pawvis, not yet submitted to homebrew/cask.
#
# Install straight from this repo in the meantime:
#   brew install --cask ./Casks/pawvis.rb
#
# `version :latest` is not a legal value for a cask (Homebrew requires a
# real, bumpable version), so this pins the current release and its
# checksum by hand. Both were verified before writing this file:
#
#   curl -sI -L -o /dev/null -w '%{http_code}\n' \
#     https://github.com/alexandriax/pawvis/releases/download/v0.24.1/Pawvis.zip
#   # -> 200, and the redirect resolves to the exact same asset as the
#   #    permanent /latest/download/ URL (confirmed by comparing the
#   #    resolved asset id in both redirect targets)
#
#   curl -sL https://github.com/alexandriax/pawvis/releases/download/v0.24.1/Pawvis.zip \
#     | shasum -a 256
#   # -> matches both the sha256 below and the .sha256 file the release
#   #    workflow publishes alongside the zip
#
# The versioned URL below is used deliberately, not the permanent
# /latest/download/Pawvis.zip alias the README and site link to: a cask's
# `url` has to resolve to the exact bytes `sha256` describes forever, and
# /latest/download/ moves out from under that checksum on every release.
# Bumping this cask for a new Pawvis version means updating `version`,
# `sha256`, and nothing else, since the url is derived from `version`.
#
# Next step to actually publish this: `brew tap-new` a personal tap (or a
# local `homebrew-core`-style tap) to prove `brew install` works end to
# end, then open a PR against https://github.com/Homebrew/homebrew-cask
# with this file under Casks/p/pawvis.rb (casks are sharded by first
# letter of the token there), passing:
#   brew audit --new --cask Casks/p/pawvis.rb
#   brew style --cask Casks/p/pawvis.rb
# homebrew/cask also expects a `livecheck` block so their bots can detect
# new releases automatically; add one pointing at the GitHub releases API
# for alexandriax/pawvis as part of that submission.

cask "pawvis" do
  version "0.24.1"
  sha256 "4473c1af45b39cebd13bd74f345ce61cec5bd9c1f4a6bfa570e9263e29b2a712"

  url "https://github.com/alexandriax/pawvis/releases/download/v#{version}/Pawvis.zip"
  name "Pawvis"
  desc "Touch-free webcam hand and voice control"
  homepage "https://pawvis.app/"

  auto_updates true # Pawvis checks for and installs its own updates daily.
  depends_on macos: :sonoma # A bare symbol already means "at least": macOS 14+, matching Package.swift.

  app "Pawvis.app"

  caveats <<~EOS
    Pawvis moves the real cursor and posts real clicks, drags and scrolls,
    so give it a few minutes somewhere harmless before relying on it.

    On first run it asks for:
      - Camera, for hand tracking (frames are processed in memory only)
      - Accessibility, to move the cursor and click:
          System Settings -> Privacy & Security -> Accessibility -> Pawvis
        Tracking runs without this, but clicks won't land until it's granted.
      - Microphone, only if you turn on voice control

    Everything above runs on-device; see https://pawvis.app/#privacy for
    exactly what that does and does not cover.
  EOS
end
