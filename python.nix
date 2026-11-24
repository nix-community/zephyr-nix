{ python3
, zephyr-src
, pyproject-nix
, clang-tools
, gitlint
, lib
, extraPackages ? _ps: [ ]
  # Python package overrides from the caller.
  # These are applied last, so they take precedence over every other layer.
, packageOverrides ? _self: _super: { }
, pkgs
}:

let
  zephyrPackageOverrides = self: super: {
    inherit gitlint;
    # HACK: Zephyr uses pypi to install non-Python deps
    clang-format = clang-tools;

    gitlint-core = gitlint;

    # Upstream bug. Network tests for canopen-2.3.0 may fail due to fragile timing assumptions
    canopen = super.canopen.overridePythonAttrs (old: {
      doCheck = false;
    });

    # Nixpkgs puts imgtool in the top-level set as mcuboot-imgtool since 2024-10
    imgtool =
      if pkgs ? mcuboot-imgtool then pkgs.mcuboot-imgtool.override {
        python3Packages = self;
      } else super.imgtool;

    # Upstream bug. Bz is not a valid pypi package.
    bz = null;

    # Nixpkgs has moved gcovr to the top-level namespace
    gcovr =
      if super ? gcovr then super.gcovr
      else pkgs.gcovr.override {
        python3Packages = self;
      };

    # Prefer existing sphinx-lint, otherwise fall back to manual packaging.
    sphinx-lint = super.sphinx-lint or (self.buildPythonPackage {
      pname = "sphinx-lint";
      version = "1.0.0";
      format = "wheel";

      src = pkgs.fetchurl {
        url = "https://files.pythonhosted.org/packages/31/d2/a130ffba531af7cbbb0e7ad24c7d577d3de0b797437f61d3a7234ed6d836/sphinx_lint-1.0.0-py3-none-any.whl";
        hash = "sha256-YReg80Cy3HPq38V9t1MdRHfgkp+SoMGi9h5u28Jy8Lw=";
      };

      propagatedBuildInputs = [
        self.polib
        self.regex
      ];
    });

    # Nixpkgs omits spsdk from the spsdk-pyocd dependencies to break a
    # cycle, so the runtime dependency check fails. spsdk depends on
    # spsdk-pyocd, so spsdk is always present at runtime.
    spsdk-pyocd = super.spsdk-pyocd.overridePythonAttrs (old: {
      dontCheckRuntimeDeps = true;
    });

    # Prefer existing tree-sitter-cmake, otherwise build it from the sdist.
    # PyPI has no Linux or macOS wheels for it.
    tree-sitter-cmake = super.tree-sitter-cmake or (self.buildPythonPackage {
      pname = "tree-sitter-cmake";
      version = "0.7.2.post1";
      pyproject = true;

      src = pkgs.fetchurl {
        url = "https://files.pythonhosted.org/packages/d0/f4/928d5378ef701577ef1b19658fc626a8c70b32447148898771a17c3c66a1/tree_sitter_cmake-0.7.2.post1.tar.gz";
        hash = "sha256-ZKN1HKZ/NxEoIdZwV7jebsq1x+lNYFNGekt4zqs0hkA=";
      };

      build-system = [
        self.setuptools
        self.wheel
      ];

      optional-dependencies.core = [ self.tree-sitter ];

      pythonImportsCheck = [ "tree_sitter_cmake" ];
    });
  };

  python = python3.override (old: {
    self = python;
    # The caller wins. The overrides of the incoming python3 come from a
    # nixpkgs overlay, so they take precedence over the overrides below.
    packageOverrides = lib.composeManyExtensions [
      zephyrPackageOverrides
      (old.packageOverrides or (_self: _super: { }))
      packageOverrides
    ];
  });

  project = pyproject-nix.lib.project.loadRequirementsTxt {
    requirements = zephyr-src + "/scripts/requirements.txt";
  };

  invalidConstraints = project.validators.validateVersionConstraints { inherit python; };

in
lib.warnIf
  (invalidConstraints != { })
  "zephyr-pythonEnv: Found invalid Python constraints for: ${builtins.toJSON (lib.attrNames invalidConstraints)}"
  (python.withPackages (project.renderers.withPackages {
    inherit python;
    extraPackages = ps: [ ps.west ] ++ extraPackages ps;
  }))
