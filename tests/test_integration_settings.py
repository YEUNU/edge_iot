"""Verify deployment settings change account references without changing contracts."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("configure_integration", ROOT / "scripts/configure_integration.py")
configure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure)


class IntegrationSettingsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = {
            "namespace": "firstspace",
            "package_keys": {"xiaomi-miio": "org.example.xiaomi", "tuya-local": "org.example.tuya"},
            "support_url": "https://example.org/support",
        }
        self.write("integration.json", json.dumps(self.config, indent=2) + "\n")
        for driver in configure.DRIVERS:
            self.write(driver + "/config.yml", "name: Example\npackageKey: 'legacy.key'\n"
                       "permissions:\n  lan: {}\nvendorSupportInformation: 'https://example.org/old'\n")
            self.write(driver + "/profiles/device.yml", "name: example.v1\ncomponents:\n"
                       "  - id: main\n    capabilities:\n"
                       "      - id: 'firstspace.control' # keep this comment\n        version: 1\n"
                       "      - id: switch\n        version: 1\n"
                       "      - id: otherparty.shared\n        version: 1\n"
                       "    categories:\n      - name: Other\n"
                       "preferences:\n  - name: example\n    description: firstspace.control\n"
                       "metadata:\n  mnmn: SmartThingsCommunity\n  vid: old-presentation\n  extra: retained\n")
        self.write("smartthings/device-configs/device.json", json.dumps({
            "detailView": [{"capability": "firstspace.control", "version": 1},
                           {"capability": "switch"}, {"capability": "otherparty.shared"}],
            "label": "firstspace.control",
        }, indent=2) + "\n")
        self.write("smartthings/capabilities/control.json", json.dumps({
            "id": "firstspace.control", "name": "Control",
            "attributes": {"state": {"schema": {"enum": ["firstspace.control"]}}},
        }) + "\n")
        self.write("xiaomi-miio/src/init.lua", "return 'firstspace.control'\n")

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def apply(self, namespace=None):
        updates = configure.planned_updates(self.root, namespace)
        for path, content in updates.items():
            self.write(str(path.relative_to(self.root)), content)
        return updates

    def test_settings_generation_preserves_existing_identity_and_presentation(self):
        self.apply()
        self.assertEqual(configure.planned_updates(self.root), {})
        for driver in configure.DRIVERS:
            yaml = (self.root / driver / "config.yml").read_text()
            self.assertIn(self.config["package_keys"][driver], yaml)
            self.assertIn("permissions:\n  lan: {}", yaml)
            self.assertIn("vid: old-presentation", (self.root / driver / "profiles/device.yml").read_text())
            self.assertIn('namespace = "firstspace"', (self.root / driver / "src/integration_settings.lua").read_text())
        for directory in configure.PYTHON_DIRS:
            module = {}
            exec((self.root / directory / "integration_settings.py").read_text(), module)
            self.assertEqual(module["capability"]("control"), "firstspace.control")

    def test_namespace_switch_updates_only_owned_deployment_fields(self):
        self.apply()
        self.apply("secondspace")
        self.assertEqual(configure.planned_updates(self.root), {})
        config = json.loads((self.root / "integration.json").read_text())
        self.assertEqual(config["namespace"], "secondspace")
        self.assertEqual(config["package_keys"], self.config["package_keys"])
        for driver in configure.DRIVERS:
            profile = (self.root / driver / "profiles/device.yml").read_text()
            self.assertIn("- id: 'secondspace.control' # keep this comment", profile)
            self.assertIn("- id: switch", profile)
            self.assertIn("- id: otherparty.shared", profile)
            self.assertIn("description: firstspace.control", profile)
            self.assertNotIn("vid:", profile)
            self.assertIn("extra: retained", profile)
        self.assertEqual((self.root / "xiaomi-miio/src/init.lua").read_text(), "return 'firstspace.control'\n")
        value = json.loads((self.root / "smartthings/device-configs/device.json").read_text())
        self.assertEqual([item["capability"] for item in value["detailView"]],
                         ["secondspace.control", "switch", "otherparty.shared"])
        self.assertEqual(value["label"], "firstspace.control")
        definition = json.loads((self.root / "smartthings/capabilities/control.json").read_text())
        self.assertEqual(definition["id"], "secondspace.control")
        self.assertEqual(definition["attributes"]["state"]["schema"]["enum"], ["firstspace.control"])

    def test_editing_config_directly_finds_previous_generated_namespace(self):
        self.apply()
        self.config["namespace"] = "thirdspace"
        self.write("integration.json", json.dumps(self.config) + "\n")
        self.apply()
        profile = (self.root / "tuya-local/profiles/device.yml").read_text()
        self.assertIn("thirdspace.control", profile)
        self.assertEqual(configure.planned_updates(self.root), {})

    def test_planning_a_namespace_change_does_not_write_files(self):
        self.apply()
        before = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        updates = configure.planned_updates(self.root, "secondspace")
        self.assertIn(self.root / "integration.json", updates)
        self.assertEqual(before, {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()})

    def test_invalid_namespace_is_rejected_before_writing(self):
        self.apply()
        before = (self.root / "integration.json").read_bytes()
        for namespace in ("", "invalid.namespace", "space name", "quoted'namespace"):
            with self.subTest(namespace=namespace), self.assertRaises(ValueError):
                configure.planned_updates(self.root, namespace)
        self.assertEqual((self.root / "integration.json").read_bytes(), before)

    def test_generated_modules_are_not_executed_to_read_previous_namespace(self):
        self.apply()
        module_path = self.root / configure.PYTHON_DIRS[0] / "integration_settings.py"
        module_path.write_text(module_path.read_text() + "raise RuntimeError('must not execute')\n")
        updates = configure.planned_updates(self.root, "secondspace")
        self.assertIn(module_path, updates)
        self.assertNotIn("must not execute", updates[module_path])

    def test_stale_settings_are_reported_without_network_or_runtime_state(self):
        self.apply()
        module_path = self.root / configure.PYTHON_DIRS[0] / "integration_settings.py"
        module_path.write_text("# stale\n")
        updates = configure.planned_updates(self.root)
        self.assertEqual(set(updates), {module_path})

    def test_support_url_cannot_embed_credentials(self):
        self.config["support_url"] = "https://user:password@example.org/support"
        self.write("integration.json", json.dumps(self.config))
        with self.assertRaises(ValueError):
            configure.planned_updates(self.root)


if __name__ == "__main__":
    unittest.main()
