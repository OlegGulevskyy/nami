# Automatic GitHub releases

Once the workflow is merged and the six Actions secrets below are configured,
open **GitHub → Releases → Draft a new release**, choose a new tag such as
`v0.1.1` from the current `master`, and click **Publish release**. Leave the
release notes blank. Publishing the release is the intentional publishing action.
Drafts and prereleases do not distribute updates.

GitHub Actions runs tests, builds the Apple Silicon app, signs it with Developer
ID, notarizes it with Apple, signs the update with Sparkle, uploads the ZIP and
`appcast.xml` to that release, then advances the stable update feed. Nothing
needs to run on your Mac. The release is visible immediately; its downloads and
in-app update become available after the workflow completes.

The version comes from the tag. The build number is automatically chosen above
both the workflow run number and the current published build. Release versions
must increase. Tags must have the form `vMAJOR.MINOR.PATCH` without leading zeros
or prerelease suffixes. Never move or reuse a published version tag.

## One-time GitHub setup

Workflow: `.github/workflows/release.yml` in `OlegGulevskyy/nami`.
It runs on GitHub's standard Apple Silicon `macos-26` runner, using Xcode 26.2.
Pull requests run tests and an ad-hoc build without importing signing secrets.
Stable release publication runs the signing and upload steps.

Configure these repository Actions secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of the existing Developer ID Application certificate **and private key**, exported as encrypted P12. |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting that P12 export. |
| `SPARKLE_PRIVATE_KEY` | Existing Nami Sparkle private key, exported using `generate_keys --account local.nami.studio -x`. |
| `APPLE_ID` | Apple account used for notarization. |
| `APPLE_APP_SPECIFIC_PASSWORD` | Its app-specific password for notarization. |
| `APPLE_TEAM_ID` | Developer team ID. |

Use GitHub's encrypted Secrets UI or `gh secret set` with stdin. Never commit
these values or put them in release notes. Moving local signing credentials to
GitHub requires the owner's explicit confirmation before export/upload.
The existing public Sparkle key remains in `Resources/Updates.xcconfig`.
Do not generate a replacement private key: existing apps trust the current one.

The runner imports Apple credentials into a temporary keychain and reads the
Sparkle key from a private temporary file to avoid interactive Keychain prompts.
Both are removed in an `always()` cleanup step. No keys or certificates are uploaded as build
artifacts. The workflow's token is scoped to the repository; no PAT is required.

## Stable feed and failure handling

The application reads:

```
https://raw.githubusercontent.com/OlegGulevskyy/nami/updates/appcast.xml
```

The workflow creates the `updates` branch on its first successful publication.
That branch contains only the signed feed. Its download URL points at the
versioned ZIP on the corresponding GitHub release. Users need no GitHub login.

The workflow uploads assets before committing the new feed. A failed build,
notarization, or upload leaves the previous feed in place. This avoids tying
updates to GitHub's latest-release URL, which can point at an unfinished release.
GitHub's raw-content cache can delay availability briefly after promotion.

Release jobs are serialized. Downgrades and reused build numbers are rejected.
A completed release rerun is a no-op. A failed release can be retried with
**Actions → Build and release Nami → Run workflow**, entering its existing tag.
A retry can replace incomplete assets only before that version is advertised
in the stable feed. Once advertised, its ZIP is never replaced by this workflow.
If several releases are created at once, GitHub may replace older pending jobs;
retry any skipped release that is still newer than the currently published one.

GitHub release immutability must remain disabled for this workflow: assets are
attached after release publication. Enabling immutable releases would require a
separate draft-build-publish flow.

## In-app behavior

Nami uses Sparkle 2.10.0. It checks daily by default; users can disable automatic
checks or use **Nami → Check for Updates…**, Settings, or About. Users choose
when to download and install. System profiling is disabled. The app verifies
both the feed and archive signatures before installing.

Checks wait while recording or internal debugging is busy. Restarting to
install also waits for active work to finish. Recordings, models, and settings
are stored outside the app bundle and survive updates. The first installation
is manual. Snapshot mode never starts Sparkle or contacts the update feed.

## Local preparation (optional)

The same scripts can still prepare a local release:

```sh
NAMI_VERSION=0.1.1 NAMI_BUILD_NUMBER=2 ./Scripts/distribute.sh
./Scripts/prepare-update.sh
```

`prepare-update.sh` accepts an optional Markdown notes path, but none is required.
It validates the signed/notarized app and matching Sparkle key and writes local
assets under `.build/updates/`. It never publishes by itself.

## Validation

Run `swift test`, `python3 -m unittest discover -s Scripts -p 'test_*.py'`, and
`python3 Scripts/smoke.py`. Release tests exercise tag validation, monotonic
versions/builds, retries, upload failures, and atomic feed promotion. These do
not replace a two-version signed/notarized installation test. The first live
release run also verifies the GitHub-hosted credential/notarization setup.
