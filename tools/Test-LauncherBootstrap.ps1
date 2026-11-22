# Exercise the windowless bootstrap's build/image identity check with synthetic files only.
# Build-Launcher.ps1 must run first; no game image or native game executable is needed.
param([string]$ProjectRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$bootstrapPath = Join-Path $ProjectRoot 'Star Fox Assault Recomp.exe'
if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) { throw 'Build the launcher before running this check.' }

$assembly = [Reflection.Assembly]::LoadFrom($bootstrapPath)
$mode = $assembly.GetType('RecompLauncherMode',$true)
$flags = [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic
$check = $mode.GetMethod('BuildMatchesImage',$flags)
if (-not $check) { throw 'The bootstrap build/image check was not found.' }
function Invoke-BuildImageCheck([Reflection.MethodInfo]$Method, [string]$Project, [string]$Executable, [string]$Image) {
  $arguments = [object[]]::new(3)
  $arguments[0] = [string]$Project
  $arguments[1] = [string]$Executable
  $arguments[2] = [string]$Image
  return [bool]$Method.Invoke($null,$arguments)
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('launcher-bootstrap-test-' + [Guid]::NewGuid().ToString('N'))
$project = Join-Path $scratch 'portable copy'
$exeDir = Join-Path $project 'build-desktop\Release'
$dataDir = Join-Path $project 'user-data'
$imageDir = Join-Path $project 'images'
[IO.Directory]::CreateDirectory($exeDir) | Out-Null
[IO.Directory]::CreateDirectory($dataDir) | Out-Null
[IO.Directory]::CreateDirectory($imageDir) | Out-Null
try {
  $exe = Join-Path $exeDir 'assault.exe'
  $oldImage = Join-Path $scratch 'old-location.iso'
  $movedImage = Join-Path $imageDir 'assault.iso'
  [IO.File]::WriteAllBytes($exe,[byte[]](1,2,3,4))
  [IO.File]::WriteAllBytes($oldImage,[byte[]](0..255))
  [IO.File]::WriteAllBytes($movedImage,[byte[]](0..255))
  (Get-Item -LiteralPath $oldImage).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-4)
  (Get-Item -LiteralPath $movedImage).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
  $record = [ordered]@{
    schema_version = 2
    game_id = 'GF7E01'
    image = $oldImage
    image_size = (Get-Item -LiteralPath $oldImage).Length
    image_modified_utc_ticks = (Get-Item -LiteralPath $oldImage).LastWriteTimeUtc.Ticks
    image_sha256 = (Get-FileHash -LiteralPath $oldImage -Algorithm SHA256).Hash
    executable_sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
  }
  $recordPath = Join-Path $dataDir 'native-build-info.json'
  [IO.File]::WriteAllText($recordPath,($record | ConvertTo-Json),(New-Object System.Text.UTF8Encoding($false)))

  $matches = Invoke-BuildImageCheck $check $project $exe $movedImage
  if (-not $matches) { throw 'A moved copy of the same image did not reuse the native build.' }
  $saved = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
  if (-not [string]::Equals([IO.Path]::GetFullPath($movedImage),[string]$saved.image,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The bootstrap did not rebind the verified image path.'
  }
  if ([long]$saved.image_modified_utc_ticks -ne (Get-Item -LiteralPath $movedImage).LastWriteTimeUtc.Ticks) {
    throw 'The bootstrap did not rebind the verified image timestamp.'
  }

  [IO.File]::WriteAllBytes($movedImage,[byte[]](@(1..255) + @(0)))
  (Get-Item -LiteralPath $movedImage).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-1)
  $matches = Invoke-BuildImageCheck $check $project $exe $movedImage
  if ($matches) { throw 'The bootstrap reused a build for different image contents.' }
  Write-Output 'launcher bootstrap portability tests: 3 passed, 0 failed'
}
finally {
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $fullScratch = [IO.Path]::GetFullPath($scratch)
  if (-not $fullScratch.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $fullScratch) -notlike 'launcher-bootstrap-test-*') {
    throw 'Refusing to remove a test folder outside its unique temporary directory.'
  }
  if (Test-Path -LiteralPath $fullScratch) { Remove-Item -LiteralPath $fullScratch -Recurse -Force }
}
