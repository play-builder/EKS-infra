"""Downloaded executable must never run before its real archive checksum passes."""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Installer(unittest.TestCase):
    def test_checksum_failure_never_executes_and_version_mismatch_never_exports(self):
        self.assertTrue((ROOT/'scripts/install-trivy.sh').is_file(), 'checksum-before-execute installer missing')
        for case in ('valid','corrupt','wrong-version'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as td:
                root=Path(td)
                executable=f'#!/bin/sh\necho executed >>"$TEST_EXECUTED"\necho "Version: {"0.0.0" if case=="wrong-version" else "0.74.0"}"\n'.encode()
                archive=root/'fixture.tgz'
                with tarfile.open(archive,'w:gz') as tar:
                    info=tarfile.TarInfo('trivy'); info.mode=0o755; info.size=len(executable)
                    tar.addfile(info,io.BytesIO(executable))
                binary=root/'bin'; binary.mkdir()
                (binary/'curl').write_text('#!/bin/sh\nwhile [ "$1" != "-o" ]; do shift; done\ncp "$TEST_ARCHIVE" "$2"\n')
                (binary/'curl').chmod(0o755)
                path=root/'github-path'; path.touch()
                executed=root/'executed'
                env={**os.environ,'PATH':str(binary)+':'+os.environ['PATH'],'RUNNER_TEMP':td,
                     'GITHUB_PATH':str(path),'TEST_EXECUTED':str(executed),'TEST_ARCHIVE':str(archive),
                     'TRIVY_VERSION':'0.74.0','TRIVY_ARCHIVE_SHA256':('0'*64 if case=='corrupt' else hashlib.sha256(archive.read_bytes()).hexdigest())}
                result=subprocess.run(['bash',str(ROOT/'scripts/install-trivy.sh')],env=env,text=True,capture_output=True)
                if case=='valid':
                    self.assertEqual(result.returncode,0,result.stderr)
                    self.assertTrue(executed.is_file())
                    self.assertTrue(path.read_text().strip())
                else:
                    self.assertNotEqual(result.returncode,0)
                    self.assertEqual(path.read_text(),'')
                    if case=='corrupt': self.assertFalse(executed.exists())


if __name__=='__main__': unittest.main()
