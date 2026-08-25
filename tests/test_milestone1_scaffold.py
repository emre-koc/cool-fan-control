import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class Milestone1ScaffoldContractTests(unittest.TestCase):
    def test_project_declares_required_macos_swift_and_signing_settings(self):
        project = (ROOT / "project.yml").read_text()

        self.assertRegex(project, r'macOS:\s*["\']14\.0["\']')
        self.assertRegex(project, r'SWIFT_VERSION:\s*["\']6\.0["\']')
        self.assertRegex(project, r'DEVELOPMENT_TEAM:\s*["\']2D7FVQV9WG["\']')
        self.assertRegex(
            project,
            re.compile(
                r'PRODUCT_BUNDLE_IDENTIFIER:\s*com\.alpico\.coolfancontrol\s*$',
                re.MULTILINE,
            ),
        )
        self.assertRegex(
            project,
            re.compile(
                r'PRODUCT_BUNDLE_IDENTIFIER:\s*com\.alpico\.coolfancontrol\.helper\s*$',
                re.MULTILINE,
            ),
        )

    def test_app_and_helper_targets_depend_on_and_import_core(self):
        project = (ROOT / "project.yml").read_text()
        app_source = (ROOT / "App/Sources/CoolFanControlApp.swift").read_text()
        helper_source = (ROOT / "Helper/Sources/main.swift").read_text()

        self.assertEqual(project.count("- package: FanControlCore"), 2)
        self.assertIn("import FanControlCore", app_source)
        self.assertIn("import FanControlCore", helper_source)

    def test_bootstrap_uses_repository_paths_and_explicit_spec(self):
        bootstrap = (ROOT / "scripts/bootstrap.sh").read_text()

        self.assertIn('cd "$(dirname "$0")/.."', bootstrap)
        self.assertIn("xcodegen generate --spec project.yml", bootstrap)
        self.assertIn("CoolFanControl.xcodeproj", bootstrap)

    def test_python_contract_cache_is_ignored(self):
        gitignore = (ROOT / ".gitignore").read_text()

        self.assertIn("__pycache__/", gitignore)

    def test_test_script_runs_contract_core_and_native_builds(self):
        script = (ROOT / "scripts/test.sh").read_text()

        self.assertIn("python3 -m unittest discover -s tests -v", script)
        self.assertIn("swift test --package-path Core", script)
        self.assertIn("scripts/bootstrap.sh", script)
        self.assertRegex(script, r'xcodebuild[^\n]*-scheme CoolFanControl[^\n]*build')
        self.assertRegex(script, r'xcodebuild[^\n]*-scheme helperd[^\n]*build')
        self.assertIn("generic/platform=macOS", script)
        self.assertNotIn("Simulator", script)


if __name__ == "__main__":
    unittest.main()
