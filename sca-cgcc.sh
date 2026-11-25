# nixpkgs builds the host GCC and the host glibc headers into sparse and cgcc,
# and sparse does not define all the architecture macros of the target, for
# example __XTENSA_EL__ or __ARM_ARCH_7M__. Give sparse the include directories
# and the predefined macros of the target compiler (REAL_CC). CHECK sends them
# only to sparse, because the target compiler already has them.

real_cc=${REAL_CC:-cc}

# The include directories and the macros depend on the target flags of the call.
target_flags=()
nostdinc=false
prev=
for arg in "$@"; do
  case $prev in
  --sysroot | -B) target_flags+=("$prev" "$arg") ;;
  esac
  case $arg in
  -nostdinc) nostdinc=true ;;
  -m* | --sysroot=* | -B?* | -specs=* | --specs=*) target_flags+=("$arg") ;;
  esac
  prev=$arg
done

# The macros go to stdout, the include directories to stderr. Keep the macros
# that sparse or cgcc define already, for example the float limits.
macros=$(mktemp)
trap 'rm -f "$macros"' EXIT
search=$("$real_cc" "${target_flags[@]}" -E -dM -Wp,-v - </dev/null 2>&1 >"$macros")
sed -i -E 's/^#define ([A-Za-z0-9_]+)(.*)$/#ifndef \1\n#define \1\2\n#endif/' "$macros"

# cgcc adds the predefined macros of the host OS (uname), but a Zephyr target
# has no OS.
check=("$SPARSE/bin/sparse" -U__linux__ -U__linux -Ulinux -U__gnu_linux__ -U__unix__ -U__unix -Uunix)
check+=(-include "$macros")
if [ "$nostdinc" = false ]; then
  check+=(-nostdinc)
  while read -r dir; do
    check+=(-isystem "$dir")
  done < <(sed -n '/search starts here/,/End of search/s/^ //p' <<<"$search")
fi

CHECK=$(printf '%q ' "${check[@]}")
export CHECK
"$SPARSE/bin/cgcc" "$@"
