# The vast.ai CLI/SDK (https://pypi.org/project/vastai/) — not in nixpkgs.
{ lib
, buildPythonApplication
, fetchPypi
, poetry-core
, poetry-dynamic-versioning
, aiodns
, aiohttp
, anyio
, argcomplete
, cryptography
, curlify
, pillow
, psutil
, pycares
, pycryptodome
, pyparsing
, python-dateutil
, requests
, rich
, typing-extensions
, urllib3
, xdg
}:

buildPythonApplication rec {
  pname = "vastai";
  version = "1.5.2";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-rJzpc921dr3klnNaLh3KWHRuCT+7FgNqMi27yN153XY=";
  };

  build-system = [ poetry-core poetry-dynamic-versioning ];

  # Upstream pins exact versions (cryptography==49.0.0, pycares==4.11.0, ...)
  # that nixpkgs is a release or two off; the CLI works fine against them.
  pythonRelaxDeps = true;

  # borb is only touched by vastai/pdf/vast_pdf.py — a deprecated shim nothing
  # imports, behind a try/except ImportError. nixpkgs carries borb 3.x, whose
  # API the 2.1 imports there don't match anyway. Only PDF invoice generation
  # is affected.
  pythonRemoveDeps = [ "borb" ];

  dependencies = [
    aiodns
    aiohttp
    anyio
    argcomplete
    cryptography
    curlify
    pillow
    psutil
    pycares
    pycryptodome
    pyparsing
    python-dateutil
    requests
    rich
    typing-extensions
    urllib3
    xdg
  ];

  # vastai.cli.util creates its config dir at import time, so the import check
  # needs a writable HOME (the sandbox's /homeless-shelter is not).
  postPatch = ''
    export HOME=$TMPDIR
  '';

  pythonImportsCheck = [ "vastai" "vastai.cli.main" ];

  # No test suite ships in the sdist.
  doCheck = false;

  meta = {
    description = "CLI and SDK for the Vast.ai GPU cloud";
    homepage = "https://github.com/vast-ai/vast-cli";
    license = lib.licenses.mit;
    mainProgram = "vastai";
  };
}
