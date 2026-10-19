import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('policy', Path(__file__).with_name('check_public_source.py'))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class PublicSourcePolicyTest(unittest.TestCase):
    def test_recognized_credentials_are_reported_without_printing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            credential = 'ghp_' + 'a' * 40
            (root / 'source.dart').write_text(credential)
            issues = policy.inspect(root)
            self.assertEqual(len(issues), 1)
            self.assertNotIn(credential, issues[0])

    def test_private_paths_signing_files_and_device_identifiers_are_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'key.properties').write_text('fixture')
            (root / 'project.iml').write_text('fixture')
            (root / 'machine.txt').write_text('/' + 'Users/private/project')
            (root / 'device.txt').write_text('adb -s ' + 'ABCD1234567890')
            self.assertEqual(len(policy.inspect(root)), 4)

    def test_public_api_identifier_and_embedded_binary_are_not_private_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'protocol.dart').write_text("const token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';")
            (root / 'libcpp.so').write_bytes(b'\x7fELF\xff\x00')
            self.assertEqual(policy.inspect(root), [])

    def test_worker_secret_files_and_local_state_are_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['tools/update-mirror/.dev.vars.production',
                         'tools/content-gateway/.env.local',
                         'tools/update-mirror/.wrangler/state/local.txt']:
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('fixture')
            self.assertEqual(len(policy.inspect(root)), 3)

    def test_windows_sdk_version_is_not_an_ip_but_actual_lan_address_is(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'sdk.xml'
            source.write_text('WindowsTargetPlatformVersion=10.0.19041.0')
            self.assertEqual(policy.inspect(root), [])
            source.write_text('https://' + '192.168.' + '2.10/')
            self.assertEqual(len(policy.inspect(root)), 1)

    def test_only_exact_upstream_examples_are_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'third_party/libmobi/src/read.c'
            source.parent.mkdir(parents=True)
            source.write_text(policy.UPSTREAM_PATH_EXAMPLES[source.relative_to(root).as_posix()])
            self.assertEqual(policy.inspect(root), [])
            source.write_text(source.read_text() + '\n/' + 'Users/private/local-book')
            self.assertEqual(len(policy.inspect(root)), 1)


if __name__ == '__main__':
    unittest.main()
