# nixpkgs makes these tools for the host: their wrappers add the host glibc
# and GCC headers. A Zephyr target must use the headers and runtimes of the
# Zephyr SDK instead.
{
  lib,
  symlinkJoin,
  makeWrapper,
  llvmPackages,
}:

let
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
