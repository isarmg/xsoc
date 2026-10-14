[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$ClientExe,
    [Parameter(Mandatory=$true)][string]$MaintenanceExe,
    [Parameter(Mandatory=$true)][string]$SmartmontoolsDir
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$work=Join-Path $env:TEMP ('xsoc-reviewed-msi-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $project=Join-Path $PSScriptRoot 'Xsoc.Installer.wixproj'
    $client=(Resolve-Path -LiteralPath $ClientExe).Path
    # Cargo may hardlink its top-level executable to its deps artifact. The
    # package authority reads one private regular file used by both MSI builds.
    $maintenance=Join-Path $work 'xsoc-maintenance.exe'
    Copy-Item -LiteralPath (Resolve-Path -LiteralPath $MaintenanceExe).Path -Destination $maintenance
    $maintenance=(Resolve-Path -LiteralPath $maintenance).Path
    $smart=(Resolve-Path -LiteralPath $SmartmontoolsDir).Path
    $common=@('-c','Release',"-p:ProductVersion=$Version","-p:ClientExe=$client","-p:MaintenanceExe=$maintenance","-p:SmartmontoolsDir=$smart","-p:BaseIntermediateOutputPath=$work\obj\")
    & dotnet build $project @common "-p:OutputPath=$work\bootstrap\"
    if ($LASTEXITCODE) { throw 'Bootstrap MSI build failed' }
    $bootstrap=Join-Path $work "bootstrap\xsoc-$Version-x64.msi"
    $payload=Join-Path $work 'payload'
    & python (Join-Path $root 'scripts/extract-bootstrap-msi.py') --bootstrap-msi $bootstrap --stage $payload
    if ($LASTEXITCODE) { throw 'Bootstrap MSI extraction failed' }
    & python (Join-Path $root 'scripts/wix-runtime-inventory.py') --stage $payload --bootstrap-msi $bootstrap --build-input-root "$work\runtime-inputs" --output "$work\runtime-components.json" --project $project --owned-input $maintenance --owned-input (Join-Path $root 'packaging/windows/License.rtf')
    if ($LASTEXITCODE) { throw 'WiX runtime source/license verification failed' }
& python (Join-Path $root 'scripts/prepare-msi-policy.py') --source (Join-Path $root 'packaging/windows/wix/Package.wxs') --stage $payload --version $Version
if ($LASTEXITCODE) { throw 'Current MSI source installation policy failed' }
    & python (Join-Path $root 'scripts/prepare-native-inventory.py') --stage $payload --version $Version --target x86_64-pc-windows-msvc --smart-origin (Join-Path (Split-Path -Parent $smart) 'smartmontools-7.5.win32-setup.exe') --external-components "$work\runtime-components.json" --build-input-root "$work\runtime-inputs"
    if ($LASTEXITCODE) { throw 'Actual native MSI inventory failed' }
    & python (Join-Path $root 'scripts/wix-inventory-files.py') --directory "$payload\share" --output "$work\inventory.wxs" --product xsoc
    if ($LASTEXITCODE) { throw 'Full MSI inventory authoring failed' }
    $output=Join-Path $PSScriptRoot 'bin/x64/Release'
    & dotnet build $project @common "-p:OutputPath=$output\" '-p:IncludeInventory=1' "-p:InventoryWxs=$work\inventory.wxs"
    if ($LASTEXITCODE) { throw 'Final MSI build failed' }
    $metadata=Join-Path $root 'dist/native-inventory'
    New-Item -ItemType Directory -Force -Path $metadata | Out-Null
    Copy-Item -LiteralPath (Join-Path $payload 'share/release-sbom.cdx.json') -Destination (Join-Path $metadata 'windows-inner.cdx.json')
}
finally { Remove-Item -LiteralPath $work -Recurse -Force }
