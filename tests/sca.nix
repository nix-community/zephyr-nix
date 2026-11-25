# The exit code of the build does not show that a tool worked, because some
# variants continue when their tool fails. So each check requires a report of
# the defect in sca-fixture.c.
#
# The gcc and dtdoctor variants need no tool from zephyr-nix, so they have no
# check.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  cmake,
  ninja,
  jq,
  zephyr-src,
  zephyr-nix,
}:

let
  # The Arm Cortex-M boards need the CMSIS_6 module.
  cmsis_6 =
    let
      rev = "1c1840af7a7e757d6e2fec3ddb0e5ce0dfcc93c8";
    in
    assert lib.assertMsg (lib.hasInfix rev (builtins.readFile "${zephyr-src}/west.yml"))
      "zephyr-nix: set the CMSIS_6 revision in tests/sca.nix to the one in the west.yml of Zephyr.";
    fetchFromGitHub {
      owner = "zephyrproject-rtos";
      repo = "CMSIS_6";
      inherit rev;
      hash = "sha256-IiE4Wzh1aWgPI589n7CaoDM8l25KtrRsGwUF0r74b18=";
    };

  mkCheck =
    variant:
    {
      tool,
      # The clang based tools do not know the GCC flags in the compile
      # commands of the GNU toolchain.
      toolchain ? "zephyr/llvm",
      board ? "qemu_cortex_m3",
      targets ? [ ],
      modules ? [ cmsis_6 ],
      verify,
    }:
    stdenvNoCC.mkDerivation {
      name = "zephyr-sca-check-${variant}";

      dontUnpack = true;
      dontUseCmakeConfigure = true;

      nativeBuildInputs = [
        (zephyr-nix.sdk.override {
          inherit targets;
          withLlvm = toolchain == "zephyr/llvm";
        })
        zephyr-nix.pythonEnv
        tool
        cmake
        ninja
      ];

      buildPhase = ''
        runHook preBuild

        # The Nix store is read-only, and the fixture changes main.c.
        cp -r ${zephyr-src} zephyr
        chmod -R u+w zephyr
        cat ${./sca-fixture.c} >> zephyr/samples/hello_world/src/main.c
        export ZEPHYR_BASE=$PWD/zephyr

        cmake -B build -S zephyr/samples/hello_world -GNinja \
          -DBOARD=${board} \
          -DZEPHYR_TOOLCHAIN_VARIANT=${toolchain} \
          -DZEPHYR_SCA_VARIANT=${variant} \
          -DZEPHYR_MODULES=${lib.escapeShellArg (lib.concatStringsSep ";" modules)} \
          2>&1 | tee build.log
        cmake --build build 2>&1 | tee -a build.log

        runHook postBuild
      '';

      doCheck = true;
      checkPhase = ''
        runHook preCheck

        fail() {
          printf 'zephyr-sca-check: %s\n' "$1" >&2
          exit 1
        }

        ${verify}

        runHook postCheck
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        cp build.log $out/
        if [ -d build/sca ]; then
          cp -r build/sca $out/
        fi
        runHook postInstall
      '';
    };

in
lib.mapAttrs mkCheck {
  clang = {
    tool = zephyr-nix.sca.clang;
    verify = ''
      grep -rlq "Dereference of null pointer" build/sca/clang \
        || fail "the clang static analyzer did not report the fixture"
    '';
  };
}
