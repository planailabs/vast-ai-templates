{ lib, stdenv, autoPatchelfHook, fetchurl, python3 }:

let
  truss-transfer = python3.pkgs.buildPythonPackage {
    pname = "truss-transfer";
    version = "0.0.43";
    format = "wheel";
    src = fetchurl {
      name = "truss_transfer-0.0.43-cp38-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
      url = "https://files.pythonhosted.org/packages/08/72/18f4cc06fe193e3d80119a12e857090f15c2286c79b12bdff75940aec276/truss_transfer-0.0.43-cp38-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
      hash = "sha256-GYIQ+lGVg/eS6Lbnk+gQkARuF5KVB+zKHawK6bfZ5P8=";
    };
    nativeBuildInputs = lib.optional stdenv.isLinux autoPatchelfHook;
    buildInputs = lib.optional stdenv.isLinux stdenv.cc.cc.lib;
    pythonImportsCheck = [ "truss_transfer" ];
  };
in
python3.pkgs.buildPythonApplication rec {
  pname = "truss";
  version = "0.18.25";
  format = "wheel";
  src = fetchurl {
    name = "truss-${version}-py3-none-any.whl";
    url = "https://files.pythonhosted.org/packages/9e/a5/ba315a16dbfb27eb36fba1e44dce7713c2588f7012af7834aa97925d79f4/truss-${version}-py3-none-any.whl";
    hash = "sha256-OG7GjstbyxxYLSZ2XMR8NBku8JL/0ZNCJO0wjAY7i1o=";
  };
  dontCheckRuntimeDeps = true;
  dependencies = with python3.pkgs; [
    aiofiles
    blake3
    boto3
    click
    google-cloud-storage
    httpx
    httpx-ws
    huggingface-hub
    inquirerpy
    jinja2
    keyring
    libcst
    loguru
    packaging
    pathspec
    psutil
    pydantic
    python-json-logger
    python-on-whales
    pyyaml
    requests
    rich
    rich-click
    ruff
    tenacity
    tomlkit
    watchfiles
    truss-transfer
  ];
  pythonImportsCheck = [ "truss" ];
  meta = {
    description = "Baseten's model packaging and deployment CLI";
    homepage = "https://truss.baseten.co";
    mainProgram = "truss";
  };
}
