import os
import pathlib
import subprocess
import tempfile

root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="lua-installer-negative-") as directory:
    path=pathlib.Path(directory)
    (path/"bad.tar.gz").write_bytes(b"untrusted source")
    result=subprocess.run(["bash",str(root/"scripts/install-lua.sh"),str(path/"bin")],
                          env={**os.environ,"LUA_SOURCE_ARCHIVE":str(path/"bad.tar.gz")},capture_output=True,text=True)
    assert result.returncode != 0 and "LUA_SOURCE_CHECKSUM_MISMATCH" in result.stderr, result.stderr
    assert not (path/"bin/lua").exists()
print("PASS: untrusted Lua archive rejected before extraction, build or install")
