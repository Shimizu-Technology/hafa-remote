# HR-057: Public TestFlight candidate 1.0 (12)

Delivers the App Review response build to Leon through TestFlight. Leon tests it before deciding to resubmit. This ticket does not resubmit to App Review.

## Source

- The public build number moves from 9 to 12 in the app and the Control Center extension. Preflight, the upload-readiness validator and its fixtures expect 12. The internal audience stays at 11.
- An authenticated read of the build inventory on November 1, 2026 showed builds 1–11, all `VALID`. App Store version 1.0 is in the Rejected state, so it can take a new build.
- The candidate includes HR-054 (reconnect reliability), HR-055 (brand-neutral public build and listing) and HR-056 (review-facing clarity).

## Store images

The five store composites are regenerated from the final `HafaRemotePublic` / `ReleasePublic` interface on an iPhone 17 Pro Max simulator (1320 × 2868), with manufacturer-free captions. Scenes:

- first launch (with **Try Without a TV**)
- the labeled offline demo
- pairing help
- Help
- diagnostics off by default

No interface, connection or TV response is invented.

## Delivery

The upload follows the existing public path:

1. Archive and export from the exact merged source with `--audience public`.
2. Run strict preflight on the archive and export.
3. Use a private release-evidence receipt built from live checks: privacy policy live, App Privacy label published, release Manual.
4. Upload the exact validated IPA with `altool`.

After upload, verify that build 12 is `VALID` and App Store eligible, and that Leon's existing internal TestFlight group can install it.

## Left for Leon

- Test the candidate on the Q70AA. The checklist is in `testflight_what_to_test.txt`.
- Record the hardware video and decide whether to resubmit, using the resubmission packet prepared alongside this ticket: the App Review reply draft, the App Store Connect field changes and the video shot list.
