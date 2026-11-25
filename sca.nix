# nixpkgs makes these tools for the host: their wrappers add the host glibc
# and GCC headers. A Zephyr target must use the headers and runtimes of the
# Zephyr SDK instead.
#
# The clang based tools find the target runtimes (multilib.yaml, picolibc)
# relative to the install directory of their driver. They are not in nixpkgs,
# only in the LLVM toolchain of the SDK, so the wrappers point the driver to
# the SDK of the build at run time. A copy of the SDK here would add a second
# LLVM toolchain to the closure, and it could differ from the one that
# compiles the code.
{
  lib,
  stdenv,
  symlinkJoin,
  makeWrapper,
  writeShellApplication,
  llvmPackages,
  codechecker,
  include-what-you-use,
  sparse,
}:

let
  sdkLlvmBin = ''
    if [ ! -x "''${ZEPHYR_SDK_INSTALL_DIR:-}/llvm/bin/clang" ]; then
      echo "zephyr-nix: ZEPHYR_SDK_INSTALL_DIR must point to an SDK with the LLVM toolchain (sdk.override { withLlvm = true; })" >&2
      exit 1
    fi
    sdk_llvm_bin=$ZEPHYR_SDK_INSTALL_DIR/llvm/bin
  '';

  # The unwrapped nixpkgs binaries do not find the builtin headers of their
  # own clang, because nixpkgs puts them in another output.
  resourceDir = clang: "-resource-dir=${clang}/resource-root";

  clang-tidy = writeShellApplication {
    name = "clang-tidy";
    text = ''
      ${sdkLlvmBin}
      exec ${llvmPackages.clang-unwrapped}/bin/clang-tidy \
        --extra-arg-before=-ccc-install-dir --extra-arg-before="$sdk_llvm_bin" \
        --extra-arg-before=${resourceDir llvmPackages.clang} \
        "$@"
    '';
  };

  tools = {
    # analyze-build is in the `python` output of clang, but its libscanbuild
    # module is in the `lib` output.
    clang = symlinkJoin {
      name = "zephyr-sca-clang-${llvmPackages.clang-unwrapped.version}";
      paths = [ llvmPackages.clang-unwrapped.python ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/analyze-build \
          --prefix PYTHONPATH : ${llvmPackages.clang-unwrapped.lib}/lib
      '';
      meta.mainProgram = "analyze-build";
    };

    # Zephyr always configures cppcheck. clangsa runs the clang of the SDK,
    # because the nixpkgs clang does not find the target runtimes. The SDK
    # has no clang-tidy.
    codechecker =
      let
        base = codechecker.override { withCppcheck = true; };
      in
      symlinkJoin {
        name = "zephyr-sca-codechecker-${base.version}";
        paths = [ base ];
        nativeBuildInputs = [ makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/CodeChecker \
            --run ${lib.escapeShellArg sdkLlvmBin} \
            --run 'export PATH=${lib.getBin clang-tidy}/bin:$sdk_llvm_bin:$PATH'
          # CodeChecker propagates its Python interpreter and modules. In a
          # shell, they would come before the pythonEnv of Zephyr on PATH and
          # PYTHONPATH. The wrapper does not need them.
          rm -r $out/nix-support
        '';
        meta.mainProgram = "CodeChecker";
      };

    # The nixpkgs wrapper adds the host glibc headers with CPATH, so use the
    # unwrapped binary.
    iwyu = writeShellApplication {
      name = "include-what-you-use";
      text = ''
        ${sdkLlvmBin}
        exec ${include-what-you-use}/bin/.include-what-you-use-unwrapped \
          -ccc-install-dir "$sdk_llvm_bin" ${resourceDir include-what-you-use.clang} \
          "$@"
      '';
    };
  }
  # nixpkgs supports sparse only on Linux.
  // lib.optionalAttrs (lib.meta.availableOn stdenv.hostPlatform sparse) {
    sparse =
      let
        cgcc = writeShellApplication {
          name = "cgcc";
          runtimeEnv.SPARSE = sparse;
          text = builtins.readFile ./sca-cgcc.sh;
        };
      in
      symlinkJoin {
        name = "zephyr-sca-sparse-${sparse.version}";
        # The cgcc wrapper must come first to hide the cgcc of sparse.
        paths = [
          cgcc
          sparse
        ];
        meta.mainProgram = "cgcc";
      };
  };
in
lib.recurseIntoAttrs (
  tools
  // {
    all = symlinkJoin {
      name = "zephyr-sca-all";
      paths = lib.attrValues tools;
    };
  }
)
