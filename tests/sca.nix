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

  # The Xtensa boards need the hal_xtensa module.
  hal_xtensa =
    let
      rev = "60224c27bed1466287f0246ac04c902b92331c29";
    in
    assert lib.assertMsg (lib.hasInfix rev (builtins.readFile "${zephyr-src}/west.yml"))
      "zephyr-nix: set the hal_xtensa revision in tests/sca.nix to the one in the west.yml of Zephyr.";
    fetchFromGitHub {
      owner = "zephyrproject-rtos";
      repo = "hal_xtensa";
      inherit rev;
      hash = "sha256-YOAUyNhENoxGSp5WEndvaWdXiy61jGPHzGFg4xyoq8o=";
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
      # The build target. Empty for all targets.
      target ? "",
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
        jq
      ];

      buildPhase = ''
        runHook preBuild

        export HOME=$TMPDIR

        # The Nix store is read-only, and the fixture changes main.c.
        # CodeChecker also cannot put files with the timestamps of the Nix
        # store into a ZIP archive.
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
        cmake --build build ${lib.optionalString (target != "") "--target ${target}"} 2>&1 \
          | tee -a build.log

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

  codechecker = {
    tool = zephyr-nix.sca.codechecker;
    verify = ''
      plist=build/sca/codechecker/codechecker.plist
      jq -e '.tools[0].analyzers
        | (keys | contains(["clangsa", "clang-tidy", "cppcheck"]))
          and all(.[].analyzer_statistics; .successful > 0 and .failed == 0)' \
        $plist/metadata.json \
        || fail "an analyzer of CodeChecker did not run, or failed"
      grep -q '<string>core.NullDereference</string>' $plist/main.c_clangsa_*.plist \
        || fail "clangsa did not report the fixture"
      grep -q '<string>cppcheck-nullPointer</string>' $plist/main.c_cppcheck_*.plist \
        || fail "cppcheck did not report the fixture"
    '';
  };

  iwyu = {
    tool = zephyr-nix.sca.iwyu;
    verify = ''
      grep -Eq "hello_world/src/main.c (should add these lines|has correct #includes)" build.log \
        || fail "include-what-you-use did not analyze main.c"
    '';
  };

  sparse = {
    tool = zephyr-nix.sca.sparse;
    toolchain = "zephyr";
    # The board of the sparse documentation of Zephyr.
    board = "intel_adsp/cavs25";
    targets = [ "xtensa-intel_tgl_adsp_zephyr-elf" ];
    modules = [ hal_xtensa ];
    # The final image of this board needs west sign, which needs a west
    # workspace. sparse runs when the sources compile.
    target = "zephyr/zephyr.elf";
    # Without the macros of the target compiler, sparse reports errors in the
    # headers of the target, for example "Endianess not declared".
    verify = ''
      grep -q "symbol 'zephyr_nix_sca_fixture' was not declared" build.log \
        || fail "sparse did not report the fixture"
      if grep -E ':[0-9]+:[0-9]+: error:' build.log; then
        fail "sparse reported errors"
      fi
    '';
  };
}
