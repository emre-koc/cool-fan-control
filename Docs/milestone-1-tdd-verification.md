# Milestone 1 TDD verification record

- **Date:** 2026-08-25
- **Scope:** Milestone 1 — repository and toolchain scaffold

## RED

Before implementation, the scaffold contract suite was run with:

```sh
python3 -m unittest discover -s tests -v
```

The first execution discovered four contract tests and produced four failures. One failure came from an incorrect bundle-ID regex in the contract test itself; it was a test design error, not a missing scaffold requirement.

The regex was corrected before implementation. The rerun still discovered four contract tests and produced these three valid expected scaffold failures:

1. `test_app_and_helper_targets_depend_on_and_import_core` — the app and helper did not yet import `FanControlCore`.
2. `test_bootstrap_uses_repository_paths_and_explicit_spec` — bootstrap did not yet pass the explicit `project.yml` spec to XcodeGen.
3. `test_test_script_runs_contract_core_and_native_builds` — the test script did not yet perform the required native app and helper build verification.

The cache-ignore contract was added later as the fifth test and failed in a separate RED cycle because `__pycache__/` was absent. Retrospectively, running the current five-test suite against `HEAD` produces four failures, consistent with that later test inclusion.

## GREEN

The final verification command was:

```sh
scripts/test.sh
```

It completed with these outcomes:

- Contract suite: five tests discovered, five passed.
- `FanControlCore`: one test executed, one passed.
- `CoolFanControl` app build: `BUILD SUCCEEDED`.
- `helperd` build: `BUILD SUCCEEDED`.

## Reproducibility

Regenerating the Xcode project and hashing `CoolFanControl.xcodeproj/project.pbxproj` produced the same SHA-256 value:

```text
64fbc6ab2b6b4941543c3e61a31c4caf3a84815fa38962b930e4fa0bb8bc6132
```

## Evidence provenance

This durable record summarizes the Hermes implementation transcript; it does not claim to preserve raw command logs. The spec reviewer independently reproduced the four-failure `HEAD` baseline and the five-test passing working-tree behavior, confirming the recorded RED/GREEN distinction.
