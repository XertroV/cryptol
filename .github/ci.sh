#!/usr/bin/env bash

BIN=bin
EXT=""
[[ "$RUNNER_OS" == 'Windows' ]] && EXT=".exe"

function is_exe() { [[ -x "$1/$2$EXT" ]] || which "$2" > /dev/null 2>&1; }

function extract_exe() {
  exe="$(cabal v2-exec which "$1$EXT")"
  name="$(basename "$exe")"
  echo "Copying $name to $2"
  mkdir -p "$2"
  cp -f "$exe" "$2/$name"
}

function setup_external_tools() {
  is_exe "$BIN" "test-runner" && return
  cabal v2-install --install-method=copy --installdir="$BIN" test-lib
}

function setup_dist_bins() {
  is_exe "dist" "cryptol" && is_exe "dist" "cryptol-html" && return
  extract_exe "cryptol" "dist"
  extract_exe "cryptol-html" "dist"
  strip dist/cryptol*
}

function install_z3() {
  is_exe "$BIN" "z3" && return
  version="$1"
  mkdir -p "$BIN"

  case "$RUNNER_OS" in
    Linux) file="ubuntu-16.04.zip" ;;
    macOS) file="osx-10.14.6.zip" ;;
    Windows) file="win.zip" ;;
  esac
  curl -o z3.zip -sL "https://github.com/Z3Prover/z3/releases/download/z3-$version/z3-$version-x64-$file"

  if [[ "$RUNNER_OS" == 'Windows' ]]; then 7z x -bd z3.zip else unzip z3.zip; fi
  cp z3-*/bin/z3$EXT $BIN/z3$EXT
  [[ "$RUNNER_OS" != 'Windows' ]] && chmod +x $BIN/z3
  rm z3.zip
}

function install_cvc4() {
  is_exe "$BIN" "cvc4" && return
  version="${1#4.}" # 4.y.z -> y.z
  mkdir -p "$BIN"
  case "$RUNNER_OS" in
    Linux) file="x86_64-linux-opt" ;;
    Windows) file="win64-opt.exe" ;;
    macOS) brew tap cvc4/cvc4 && brew install cvc4/cvc4/cvc4 && return ;;
  esac
  curl -o cvc4 -sL "https://github.com/CVC4/CVC4/releases/download/1.7/cvc4-$version-$file"
  [[ "$RUNNER_OS" != 'Windows' ]] && chmod +x cvc4
  mv cvc4 "$BIN/cvc4$EXT"
}

function install_yices() {
  is_exe "$BIN" "yices" && return
  version="$1"
  mkdir -p "$BIN"
  ext=".tar.gz"
  case "$RUNNER_OS" in
    Linux) file="pc-linux-gnu-static-gmp.tar.gz" ;;
    macOS) file="apple-darwin18.7.0-static-gmp.tar.gz" ;;
    Windows) file="pc-mingw32-static-gmp.zip" && ext=".zip" ;;
  esac
  curl -o "yices$ext" -sL "https://yices.csl.sri.com/releases/$version/yices-$version-x86_64-$file"

  if [[ "$RUNNER_OS" == "Windows" ]]; then
    7z x -bd "yices$ext"
    mv "yices-$version"/*.exe "$BIN"
  else
    tar -xzf "yices$ext"
    pushd "yices-$version" || exit
    sudo ./install-yices
    popd || exit
  fi
  rm -rf "yices$ext" "yices-$version"
}

install_deps() {
  ghc_ver="$(ghc --numeric-version)"
  cp cabal.GHC-"$ghc_ver".config cabal.project.freeze
  if [[ "$ghc_ver" == "8.8.3" && "$RUNNER_OS" == 'Windows' ]]; then JOBS=1; else JOBS=2; fi
  cabal v2-configure -j$JOBS --minimize-conflict-set
  cabal v2-build --only-dependencies exe:cryptol exe:cryptol-html
  setup_external_tools
}

install_system_deps() {
  install_z3 "$Z3_VERSION"
  install_cvc4 "$CVC4_VERSION"
  install_yices "$YICES_VERSION"
  echo "::add-path::$PWD/bin"
}

test_dist() {
  setup_dist_bins
  $BIN/test-runner --ext=.icry -F -b --exe=dist/cryptol tests
}

bundle_files() {
  doc=dist/share/doc/cryptol
  mkdir -p $doc
  cp -R examples/ $doc/examples/
  cp docs/*md docs/*pdf $doc

  # Copy the two interesting examples over
  cp docs/ProgrammingCryptol/{aes/AES,enigma/Enigma}.cry $doc/examples/
}

zip_dist() {
  if [[ "$RUNNER_OS" == Windows ]]; then 7z a -tzip -mx9 dist.zip dist; else zip -r dist.zip dist; fi
  gpg --batch --import <(echo "$SIGNING_KEY")
  fingerprint="$(gpg --list-keys | grep galois -a1 | head -n1 | awk '{$1=$1};1')"
  echo "$fingerprint:6" | gpg --import-ownertrust
  gpg --yes --no-tty --batch --pinentry-mode loopback --default-key "$fingerprint" --detach-sign -o dist.zip.sig --passphrase-file <(echo "$SIGNING_PASSPHRASE") dist.zip
}

COMMAND="$1"
shift

"$COMMAND" "$@"