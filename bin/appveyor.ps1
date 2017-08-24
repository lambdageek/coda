param(
  [string]$phase
)

$ErrorActionPreference = "Stop"
$env:PATH += ";$PWD"
$env:STACK_ROOT = 'c:\\sr'

if ($phase -eq "install") {
  "> download stack"
  Invoke-WebRequest 'http://www.stackage.org/stack/windows-i386' -OutFile 'stack.zip'
  "> unzip stack"
  7z x -y stack.zip stack.exe
  "> stack path"
  cmd /c '.\stack path 2>&1'
  $env:APPVEYOR_SAVE_CACHE_ON_ERROR = "true"
} elseif($phase -eq "build_script") {
  "> stack setup"
  cmd /c '.\stack setup 2>&1 1>&2 > nul'
  "> stack build"
  cmd /c 'echo | .\stack --no-terminal build --test --bench --ghc-options=-rtsopts'
} elseif ($phase -eq "test_script") {
  "> stack test"
  cmd /c ' .\stack test'
} elseif ($phase -eq "deploy_script") {
  "> stack install"
  cmd /c '.\stack install'
}