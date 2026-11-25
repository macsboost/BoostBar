# Builds BoostBar for Windows: the app, the screen savers, their scene pages and the installer.
#   pwsh windows/build.ps1 [-Version 1.3.73]
# Output: build/win/out/BoostBar-Setup.exe (+ .sha256). Needs the .NET SDK, Python 3 and Inno Setup 6.
param([string]$Version = "")
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
if (-not $Version) { $Version = (Get-Content VERSION -Raw).Trim() }
Write-Host "Building BoostBar $Version for Windows"

$B = "build/win"
Remove-Item -Recurse -Force "$B/app", "$B/saver", "$B/savers", "$B/out" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$B/savers", "$B/out", "build/saver" | Out-Null

dotnet build windows/BoostBar/BoostBar.csproj -c Release -p:Version=$Version -o "$B/app" --nologo
if ($LASTEXITCODE) { throw "app build failed" }
dotnet build windows/BoostBarSaver/BoostBarSaver.csproj -c Release -p:Version=$Version -o "$B/saver" --nologo
if ($LASTEXITCODE) { throw "screen saver build failed" }

# The scene pages: the same self-contained three.js pages the Mac version uses for its preview window.
$three = "build/saver/three.min.js"; $gltf = "build/saver/GLTFLoader.js"
if (-not (Test-Path $three)) { Invoke-WebRequest https://cdn.jsdelivr.net/npm/three@0.147.0/build/three.min.js -OutFile $three }
if (-not (Test-Path $gltf)) { Invoke-WebRequest https://cdn.jsdelivr.net/npm/three@0.147.0/examples/js/loaders/GLTFLoader.js -OutFile $gltf }
foreach ($scene in "cars", "starships", "starlink", "jetrace") {
  python tools/build_saver_html.py $three $gltf "$B/savers/$scene.html" $scene
  if ($LASTEXITCODE) { throw "scene page $scene failed" }
}

$iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
& $iscc "/DVersion=$Version" "/DBuildDir=$((Resolve-Path $B).Path)" windows/installer/BoostBar.iss
if ($LASTEXITCODE) { throw "installer build failed" }

$exe = "$B/out/BoostBar-Setup.exe"
$hash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  BoostBar-Setup.exe" | Set-Content -NoNewline -Encoding ascii "$exe.sha256"
Write-Host "Built $exe ($([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB)  sha256 $hash"
