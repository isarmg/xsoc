# Dot-sourced by the disposable-runner lifecycle fixture after loading msi.dll.
# These checks read compiled MSI tables and actual Windows Installer registration.
$xsocComponentGuids = @{
    ClientServiceComponent = '{56AF4FAC-C353-598B-A680-CFBE4A86F6B2}'
    ClientStateDirectoryComponent = '{C9DB8E14-008D-5261-831F-D51ED951BFB7}'
    SmartmontoolsRuntimeComponent = '{4FB7E776-817C-4C70-AB62-2DB7111DD15A}'
    SmartmontoolsComplianceComponent = '{67F64859-953F-411A-A6E6-A3D65466EEEF}'
}
$foreignComponentGuids = @(
    '{C7D313C7-1B72-4826-8FA4-5BF10928349E}',
    '{55346DF8-69D2-425D-B574-F80379CB87A2}'
)

function Read-MsiRows($Database, [string]$Query, [string[]]$Columns) {
    $view = $Database.OpenView($Query)
    try {
        [void]$view.Execute()
        while ($null -ne ($record = $view.Fetch())) {
            try {
                $row = @{}
                for ($index = 0; $index -lt $Columns.Count; $index++) {
                    $row[$Columns[$index]] = $record.StringData($index + 1)
                }
                $row
            }
            finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($record) }
        }
    }
    finally {
        [void]$view.Close()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
    }
}

function Read-XsocMsiIdentity([string]$Path) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Path, 0)
    try {
        $properties = @{}
        foreach ($row in @(Read-MsiRows $database 'SELECT `Property`, `Value` FROM `Property`' @('Name', 'Value'))) {
            $properties[$row.Name] = $row.Value
        }
        if ($properties.ProductName -ne 'xsoc' -or $properties.UpgradeCode -ne '{B4A341EC-D4B2-419F-A00B-E8E504DE9798}') {
            throw 'Compiled MSI has the wrong product or upgrade identity.'
        }
        $authoringPath=$Path+'.inventory-authoring.wxs'
        $authoringInfo=Get-Item -LiteralPath $authoringPath
        if ($authoringInfo -isnot [IO.FileInfo] -or ($authoringInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $authoringInfo.Length -gt 4194304) { throw 'Inventory authoring must be a bounded physical build input.' }
        $settings=[Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver=$null
        $reader=[Xml.XmlReader]::Create($authoringPath,$settings)
        $authoring=[Xml.XmlDocument]::new()
        try {$authoring.Load($reader)} finally {$reader.Close()}
        $inventory=@{}
        $inventoryDirectories=@{ReleaseInventoryDirectory=@{Parent='INSTALLFOLDER';Name='share'}}
        foreach ($directory in $authoring.SelectNodes('//*[local-name()="Directory"]')) {
            $directoryId=$directory.GetAttribute('Id')
            if ($inventoryDirectories.Count -ge 16384 -or $directoryId -notmatch '^InventoryDir_[0-9a-f]{24}$' -or
                $inventoryDirectories.ContainsKey($directoryId)) { throw 'Generated inventory directory identity is invalid.' }
            $inventoryDirectories[$directoryId]=@{Parent=$directory.ParentNode.GetAttribute('Id');Name=$directory.GetAttribute('Name')}
        }
        foreach ($node in $authoring.SelectNodes('//*[local-name()="Component"]')) {
            $componentId=$node.GetAttribute('Id')
            if ($inventory.Count -ge 16384 -or $componentId -notmatch '^Inventory_[0-9a-f]{32}$' -or
                $node.GetAttribute('Bitness') -ne 'always64' -or $inventory.ContainsKey($componentId)) {
                throw 'Generated inventory component identity is ambiguous or outside its bound.'
            }
            $file=@($node.SelectNodes('./*[local-name()="File"]'))
            if ($file.Count -ne 1 -or $file[0].GetAttribute('Id') -ne ($componentId+'_file') -or $file[0].GetAttribute('KeyPath') -ne 'yes') {
                throw 'Generated inventory component has no exact file key path.'
            }
            $parent=$node.ParentNode
            if ($parent.LocalName -notin @('Directory','DirectoryRef')) { throw 'Inventory component has no source directory.' }
            $inventory[$componentId]=@{Guid=([guid]$node.GetAttribute('Guid')).ToString('B').ToUpperInvariant();KeyPath=$file[0].GetAttribute('Id');Directory=$parent.GetAttribute('Id');Name=$file[0].GetAttribute('Name')}
        }
        if ($inventory.Count -eq 0) { throw 'The compiled product must include its actual inventory authoring.' }
        $compiledDirectories=@{}
        foreach ($row in @(Read-MsiRows $database 'SELECT `Directory`, `Directory_Parent`, `DefaultDir` FROM `Directory`' @('Id','Parent','Name'))) {
            $compiledDirectories[$row.Id]=$row
        }
        foreach ($id in $inventoryDirectories.Keys) {
            $expected=$inventoryDirectories[$id]
            if (-not $compiledDirectories.ContainsKey($id) -or $compiledDirectories[$id].Parent -ne $expected.Parent -or
                $compiledDirectories[$id].Name.Split(':')[0].Split('|')[-1] -ne $expected.Name) {
                throw "Compiled inventory directory differs from its exact generated source: $id"
            }
        }
        $components = @(Read-MsiRows $database 'SELECT `Component`, `ComponentId`, `Attributes`, `KeyPath`, `Directory_` FROM `Component`' @('Id', 'Guid', 'Attributes', 'KeyPath', 'Directory'))
        if ($components.Count -ne ($xsocComponentGuids.Count+$inventory.Count)) { throw 'Unexpected compiled MSI component set.' }
        $inventorySeen=@{}
        foreach ($component in $components) {
            if ($inventory.ContainsKey($component.Id)) {
                $expected=$inventory[$component.Id]
                $file=@(Read-MsiRows $database ("SELECT ``File``, ``Component_``, ``FileName`` FROM ``File`` WHERE ``File``='$($expected.KeyPath)'" ) @('Id','Component','Name'))
                if ($inventorySeen.ContainsKey($component.Id) -or $component.Guid -ne $expected.Guid -or
                    [int]$component.Attributes -ne 256 -or $component.KeyPath -ne $expected.KeyPath -or
                    $component.Directory -ne $expected.Directory -or $file.Count -ne 1 -or
                    $file[0].Component -ne $component.Id -or $file[0].Name.Split('|')[-1] -ne $expected.Name) {
                    throw "Compiled inventory component differs from its exact generated authoring: $($component.Id)"
                }
                $inventorySeen[$component.Id]=$true
                continue
            }
            if (-not $xsocComponentGuids.ContainsKey($component.Id) -or
                $component.Guid -ne $xsocComponentGuids[$component.Id] -or
                [int]$component.Attributes -ne $(if ($component.Id -eq 'ClientStateDirectoryComponent') {260} else {256})) {
                throw "Compiled component identity or x64 attribute drifted: $($component.Id)"
            }
            if ($component.Id -eq 'ClientStateDirectoryComponent') {
                $key = @(Read-MsiRows $database ("SELECT ``Root``, ``Key``, ``Name`` FROM ``Registry`` WHERE ``Registry``='$($component.KeyPath)'" ) @('Root', 'Key', 'Name'))
                if (([int]$component.Attributes -band 4) -eq 0 -or $key.Count -ne 1 -or
                    $key[0].Root -ne '2' -or $key[0].Key -ne 'Software\sarmg\xsoc' -or $key[0].Name -ne 'ManagedStateDirectory') {
                    throw 'Compiled state component has the wrong registry key path.'
                }
            }
            else {
                $expectedKey = switch ($component.Id) {
                    'ClientServiceComponent' { 'ClientExecutable' }
                    'SmartmontoolsRuntimeComponent' { 'SmartctlExecutable' }
                    'SmartmontoolsComplianceComponent' { 'SmartmontoolsLicense' }
                }
                if ($component.KeyPath -ne $expectedKey -or ([int]$component.Attributes -band 4) -ne 0) {
                    throw "Compiled file component has the wrong key path: $($component.Id)"
                }
            }
        }
        $sequence = @{}
        foreach ($row in @(Read-MsiRows $database 'SELECT `Action`, `Sequence` FROM `InstallExecuteSequence`' @('Action', 'Sequence'))) {
            $sequence[$row.Action] = [int]$row.Sequence
        }
        if ($sequence.RemoveExistingProducts -le $sequence.InstallInitialize -or
            $sequence.RemoveExistingProducts -ge $sequence.ProcessComponents -or
            $sequence.RemoveExistingProducts -ge $sequence.InstallFiles) {
            throw 'Same-family removal must run inside rollback before installing/registering new components.'
        }
        return @{ ProductCode=$properties.ProductCode; ProductVersion=$properties.ProductVersion }
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
    }
}

function Get-MsiComponentClients([string]$Guid) {
    for ($index = 0; $index -lt 4096; $index++) {
        $client = [Text.StringBuilder]::new(39)
        $result = [Xsoc.MsiNativeMethods]::MsiEnumClients($Guid, $index, $client)
        if ($result -in @(259, 1607)) { return } # NO_MORE_ITEMS / UNKNOWN_COMPONENT
        if ($result -ne 0) { throw "MsiEnumClients failed for ${Guid}: $result" }
        $client.ToString()
    }
    throw "Unbounded MSI component client list: $Guid"
}

function Assert-MsiComponentClient([string]$Guid, [string]$ProductCode, [string]$FilePath = '') {
    $clients = @(Get-MsiComponentClients $Guid)
    if ($clients.Count -ne 1 -or $clients[0] -ne $ProductCode) {
        throw "Component $Guid does not have exactly its own product client: $($clients -join ', ')"
    }
    $path = [Text.StringBuilder]::new(2048)
    [uint32]$length = $path.Capacity
    if ([Xsoc.MsiNativeMethods]::MsiGetComponentPath($ProductCode, $Guid, $path, [ref]$length) -ne 3) {
        throw "MSI does not report component $Guid locally installed."
    }
    if ($FilePath -and $path.ToString() -ine $FilePath) { throw "MSI registered the wrong file key path for ${Guid}: $path" }
}

function Assert-XsocComponentRegistration([string]$ProductCode) {
    $paths = @{
        ClientServiceComponent = (Join-Path $installedRoot 'xsoc.exe')
        ClientStateDirectoryComponent = ''
        SmartmontoolsRuntimeComponent = (Join-Path $installedRoot 'smartmontools\bin\smartctl.exe')
        SmartmontoolsComplianceComponent = (Join-Path $installedRoot 'smartmontools\COPYING.txt')
    }
    foreach ($id in $xsocComponentGuids.Keys) { Assert-MsiComponentClient $xsocComponentGuids[$id] $ProductCode $paths[$id] }
    $registered = (Get-ItemProperty -LiteralPath 'HKLM:\Software\sarmg\xsoc' -Name ManagedStateDirectory).ManagedStateDirectory
    if ($registered.TrimEnd('\') -ine $stateRoot.TrimEnd('\')) { throw 'MSI registered the wrong XSOC state root.' }
}

function Assert-XsocComponentRegistrationAbsent([string]$ProductCode) {
    if ([Xsoc.MsiNativeMethods]::MsiQueryProductState($ProductCode) -ne -1) { throw 'XSOC MSI product registration survived uninstall.' }
    foreach ($guid in $xsocComponentGuids.Values) {
        if (@(Get-MsiComponentClients $guid).Count -ne 0) { throw "XSOC component clients survived uninstall: $guid" }
    }
}

function Test-MsiComponentCoexistence([string]$CurrentMsi, [string]$ProductCode) {
    $fixtureProject = Join-Path $PSScriptRoot 'fixtures\ComponentOwner\Fixture.wixproj'
    $fixtureOutput = Join-Path $logs 'component-owner-fixture'
    $fixtureIntermediate = Join-Path $logs 'component-owner-intermediate'
    $fixturePayload = Join-Path $repositoryRoot 'target\x86_64-pc-windows-msvc\release\xsoc.exe'
    # Restore/build intermediates belong to the disposable fixture, so later
    # current-source packaging can retain its strict clean checkout guard.
    & dotnet build $fixtureProject -c Release "-p:ClientExe=$fixturePayload" `
        "-p:OutputPath=$fixtureOutput" "-p:BaseIntermediateOutputPath=$fixtureIntermediate/"
    if ($LASTEXITCODE -ne 0) { throw 'Could not build the unrelated component-owner MSI fixture.' }
    $fixturePackages = @(Get-ChildItem -LiteralPath $fixtureOutput -Filter '*.msi' -Recurse)
    if ($fixturePackages.Count -ne 1) { throw 'Expected exactly one unrelated component-owner MSI.' }
    $fixtureMsi = $fixturePackages[0].FullName
    $foreignProduct = '{7A95BCC3-EA7E-5FA4-9054-1EC80237628C}'
    $foreignRoot = Join-Path $env:ProgramFiles 'xsoc-component-owner-fixture'
    $foreignExe = Join-Path $foreignRoot 'component-owner.exe'
    $foreignRegistry = 'HKLM:\Software\sarmg\xsoc-component-owner-fixture'
    if ((Test-Path $foreignRoot) -or (Test-Path $foreignRegistry) -or
        (Get-Service xsoc-component-owner-fixture -ErrorAction SilentlyContinue) -or
        [Xsoc.MsiNativeMethods]::MsiQueryProductState($foreignProduct) -ne -1) {
        throw 'Disposable runner already contains the unrelated component-owner fixture.'
    }
    foreach ($installFirst in @('xsoc', 'owner')) {
        foreach ($removeFirst in @('xsoc', 'owner')) {
            $name = "coexist-$installFirst-$removeFirst"
            $installOrder = if ($installFirst -eq 'xsoc') { @('xsoc', 'owner') } else { @('owner', 'xsoc') }
            foreach ($product in $installOrder) {
                $msi = if ($product -eq 'xsoc') { $CurrentMsi } else { $fixtureMsi }
                Invoke-Msi /i $msi "$name-install-$product"
            }
            Assert-XsocComponentRegistration $ProductCode
            Assert-MsiComponentClient $foreignComponentGuids[0] $foreignProduct $foreignExe
            Assert-MsiComponentClient $foreignComponentGuids[1] $foreignProduct
            $foreignHash = (Get-FileHash -LiteralPath $foreignExe).Hash
            $foreignLocation = (Get-ItemProperty -LiteralPath $foreignRegistry -Name ManagedStateDirectory).ManagedStateDirectory
            $foreignService = (Get-CimInstance Win32_Service -Filter "Name='xsoc-component-owner-fixture'").PathName
            $removeOrder = if ($removeFirst -eq 'xsoc') { @('xsoc', 'owner') } else { @('owner', 'xsoc') }
            foreach ($product in $removeOrder) {
                $msi = if ($product -eq 'xsoc') { $CurrentMsi } else { $fixtureMsi }
                Invoke-Msi /x $msi "$name-remove-$product" 'PURGE=1'
                if ($product -eq 'xsoc') {
                    Assert-ClientCompletelyAbsent
                    Assert-XsocComponentRegistrationAbsent $ProductCode
                    if ($removeFirst -eq 'xsoc') {
                        Assert-MsiComponentClient $foreignComponentGuids[0] $foreignProduct $foreignExe
                        Assert-MsiComponentClient $foreignComponentGuids[1] $foreignProduct
                        if ((Get-FileHash -LiteralPath $foreignExe).Hash -ne $foreignHash -or
                            (Get-ItemProperty -LiteralPath $foreignRegistry -Name ManagedStateDirectory).ManagedStateDirectory -ne $foreignLocation -or
                            (Get-CimInstance Win32_Service -Filter "Name='xsoc-component-owner-fixture'").PathName -ne $foreignService) {
                            throw 'XSOC uninstall changed another product resource.'
                        }
                    }
                }
                else {
                    if ((Test-Path $foreignRoot) -or
                        (Get-Service xsoc-component-owner-fixture -ErrorAction SilentlyContinue) -or
                        (Get-ItemProperty -LiteralPath $foreignRegistry -Name ManagedStateDirectory -ErrorAction SilentlyContinue) -or
                        [Xsoc.MsiNativeMethods]::MsiQueryProductState($foreignProduct) -ne -1) {
                        throw 'Unrelated MSI fixture did not fully remove its own resources.'
                    }
                    foreach ($guid in $foreignComponentGuids) {
                        if (@(Get-MsiComponentClients $guid).Count -ne 0) { throw 'Unrelated fixture retained component clients.' }
                    }
                    if ($removeFirst -eq 'owner') {
                        Assert-XsocComponentRegistration $ProductCode
                        Assert-InstallLocation $installedRoot
                        Assert-MachinePathInstalled
                        Assert-ArpVersion $ProductVersion
                        if (-not (Get-Service xsoc -ErrorAction Stop)) { throw 'Other product uninstall removed the XSOC service.' }
                    }
                }
            }
            Assert-ClientCompletelyAbsent
            Write-Host "Distinct MSI component owners verified: $name"
        }
    }
}

function Get-ComponentTransitionBaselineVersion {
    $version = [version]$ProductVersion
    if ($version.Build -gt 0) { return "$($version.Major).$($version.Minor).$($version.Build - 1)" }
    if ($version.Minor -gt 0) { return "$($version.Major).$($version.Minor - 1).65535" }
    if ($version.Major -gt 0) { return "$($version.Major - 1).255.65535" }
    throw 'No smaller MSI version is available for the transition fixture.'
}

function Build-ComponentTransitionBaseline([string]$Version) {
    # The old product must run its full maintenance sequence: standard MSI
    # removal alone does not retire the preserved state's service access.
    # Compile today's source at a distinct version so both helpers can retain
    # their own rollback journals until the enclosing upgrade commits.
    $sourceRoot = Join-Path $env:RUNNER_TEMP ('xsoc-transition-source-' + [guid]::NewGuid().ToString('N'))
    $sourceRevision=(& git -C $repositoryRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceRevision -notmatch '^[0-9a-f]{40}$' -or
        @(& git -C $repositoryRoot status --porcelain --untracked-files=all).Count -ne 0) {
        throw 'The transition fixture requires the exact clean current source.'
    }
    # This private local clone retains the producer's source identity contract.
    # Independent Git objects avoid changing the checkout used by later tests.
    & git -c core.hooksPath=NUL clone --quiet --no-hardlinks --no-checkout --local $repositoryRoot $sourceRoot
    if ($LASTEXITCODE -ne 0) { throw 'Cannot clone the current transition fixture source.' }
    & git -C $sourceRoot -c core.autocrlf=false -c core.hooksPath=NUL checkout --quiet --detach $sourceRevision
    if ($LASTEXITCODE -ne 0) { throw 'Cannot check out the exact transition fixture source.' }
    $utf8 = [Text.UTF8Encoding]::new($false)
    foreach ($entry in @(
        @{ File = 'Cargo.toml'; Pattern = '(?m)(^\[workspace\.package\]\r?\nversion = ")[^"]+("\r?$)' },
        @{ File = 'Cargo.lock'; Pattern = '(?m)(^name = "xsoc"\r?\nversion = ")[^"]+("\r?$)' }
    )) {
        $path = Join-Path $sourceRoot $entry.File
        $text = [IO.File]::ReadAllText($path)
        if ([regex]::Matches($text, $entry.Pattern).Count -ne 1) {
            throw "Expected exactly one XSOC version in $($entry.File)."
        }
        $text = [regex]::Replace($text, $entry.Pattern, ('${1}' + $Version + '${2}'))
        [IO.File]::WriteAllText($path, $text, $utf8)
    }
    & git -C $sourceRoot -c core.autocrlf=false add -- Cargo.toml Cargo.lock
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage the synthetic current-source version.' }
    & git -C $sourceRoot -c core.hooksPath=NUL -c commit.gpgsign=false `
        -c user.name='XSOC current-source fixture' -c user.email='fixture@example.invalid' `
        commit --quiet --message 'Synthetic current-source component transaction fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the synthetic current-source version.' }
    $fixtureRevision=(& git -C $sourceRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $fixtureRevision -notmatch '^[0-9a-f]{40}$' -or
        @(& git -C $sourceRoot status --porcelain --untracked-files=all).Count -ne 0) {
        throw 'The synthetic transition fixture must have a clean immutable identity.'
    }
    # Seed only third-party dependency outputs using independent physical files.
    # No xsoc object, fingerprint, build-script output or executable is reused.
    # The fresh target cannot overwrite the current release Client/helper.
    $targetRoot = Join-Path $sourceRoot 'target'
    & python (Join-Path $repositoryRoot 'scripts/seed-transition-dependencies.py') `
        --source (Join-Path $repositoryRoot 'target') --destination $targetRoot | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Cannot seed independent transition dependencies.' }
    $previousBuildSha=$env:XSOC_BUILD_SHA
    try {
        $env:XSOC_BUILD_SHA=$fixtureRevision
        & cargo build --locked --release --manifest-path (Join-Path $sourceRoot 'Cargo.toml') `
            --target-dir $targetRoot --target x86_64-pc-windows-msvc --bin xsoc --bin xsoc-maintenance | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Failed to build the current-source transition baseline.' }
        $binaryRoot = Join-Path $targetRoot 'x86_64-pc-windows-msvc\release'
        $fixtureIdentityText = & (Join-Path $binaryRoot 'xsoc.exe') version --format json
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read transition executable source identity.' }
        $fixtureIdentity = ($fixtureIdentityText -join "`n") | ConvertFrom-Json
        if ($fixtureIdentity.commit -ne $fixtureRevision -or $fixtureIdentity.version -ne $Version) {
            throw 'Transition executable differs from its independently compiled source/version.'
        }
        Write-Host "Verified transition executable identity: $fixtureRevision ($Version)"
        & (Join-Path $sourceRoot 'packaging\windows\wix\build-msi.cmd') $Version `
            (Join-Path $binaryRoot 'xsoc.exe') (Join-Path $binaryRoot 'xsoc-maintenance.exe') `
            $SmartmontoolsDirectory | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Failed to package the current-source transition baseline.' }
    }
    finally { $env:XSOC_BUILD_SHA=$previousBuildSha }
    $packages = @(Get-ChildItem (Join-Path $sourceRoot 'packaging\windows\wix\bin\x64\Release') `
        -Filter '*.msi' -Recurse)
    if ($packages.Count -ne 1) { throw 'Expected exactly one compiled transition baseline MSI.' }
    $identity = Read-XsocMsiIdentity $packages[0].FullName
    if ($identity.ProductVersion -ne $Version) { throw 'Compiled transition baseline has the wrong MSI version.' }
    return $packages[0].FullName
}

function Assert-ComponentTransitionArtifactsAbsent([string]$Context, [string]$BaselineVersion) {
    foreach ($version in @($ProductVersion, $BaselineVersion)) {
        foreach ($name in @("xsoc.install-journal-$version", "xsoc.uninstall-journal-$version",
            "xsoc.purge-quarantine-$version", "xsoc.maintenance-diagnostic-$version.txt")) {
            $path = Join-Path $env:ProgramData $name
            if (Test-Path -LiteralPath $path) { throw "$Context retained a transaction artifact: $path" }
        }
    }
}

function New-ComponentTransitionFixture([string]$Source, [string]$Target, [bool]$Baseline) {
    # Both packages compile the current source with matching MSI/helper versions.
    # The baseline changes component ownership, not historical behavior.
    Copy-Item -LiteralPath $Source -Destination $Target
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Target, 1)
    try {
        $queries = @()
        if ($Baseline) {
            $queries += "UPDATE ``Property`` SET ``Value``='{E0F59096-C373-59C0-A835-FDAD36B674F0}' WHERE ``Property``='ProductCode'"
            $queries += "UPDATE ``Component`` SET ``ComponentId``='$($foreignComponentGuids[0])' WHERE ``Component``='ClientServiceComponent'"
            $queries += "UPDATE ``Component`` SET ``ComponentId``='$($foreignComponentGuids[1])' WHERE ``Component``='ClientStateDirectoryComponent'"
            $packageCode = '{1E73B362-88C2-5FC0-8109-3723DECEB0DB}'
        }
        else {
            $row = @(Read-MsiRows $database "SELECT ``Sequence`` FROM ``InstallExecuteSequence`` WHERE ``Action``='RemoveExistingProducts'" @('Sequence'))
            if ($row.Count -ne 1) { throw 'Missing transactional same-family removal action.' }
            $failureSequence = [int]$row[0].Sequence + 1
            $queries += "INSERT INTO ``CustomAction`` (``Action``, ``Type``, ``Target``) VALUES ('XsocFixtureAbortAfterRemoval', 19, 'XSOC fixture abort after old product removal')"
            $queries += "INSERT INTO ``InstallExecuteSequence`` (``Action``, ``Condition``, ``Sequence``) VALUES ('XsocFixtureAbortAfterRemoval', '1', $failureSequence)"
            $packageCode = '{9DFA525E-5BE8-5860-AE60-8991A89E7582}'
        }
        foreach ($query in $queries) {
            $view = $database.OpenView($query)
            try { [void]$view.Execute() }
            finally { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view) }
        }
        $summary = $database.SummaryInformation(20)
        try {
            [void]$summary.GetType().InvokeMember('Property', [Reflection.BindingFlags]::SetProperty,
                $null, $summary, @([int]9, $packageCode))
            [void]$summary.Persist()
        }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($summary) }
        [void]$database.Commit()
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
    }
}

function Test-MsiComponentTransition([string]$CurrentMsi, [string]$ProductCode) {
    $baseline = Join-Path $logs 'component-transition-baseline.msi'
    $failedUpgrade = Join-Path $logs 'component-transition-failure.msi'
    $baselineProduct = '{E0F59096-C373-59C0-A835-FDAD36B674F0}'
    $baselineVersion = Get-ComponentTransitionBaselineVersion
    $compiledBaseline = Build-ComponentTransitionBaseline $baselineVersion
    Assert-ComponentTransitionArtifactsAbsent 'Before component transition' $baselineVersion
    New-ComponentTransitionFixture $compiledBaseline $baseline $true
    New-ComponentTransitionFixture $CurrentMsi $failedUpgrade $false
    Invoke-Msi /i $baseline 'component-transition-baseline'
    Assert-ComponentTransitionArtifactsAbsent 'Baseline install' $baselineVersion
    Assert-MsiComponentClient $foreignComponentGuids[0] $baselineProduct (Join-Path $installedRoot 'xsoc.exe')
    Assert-MsiComponentClient $foreignComponentGuids[1] $baselineProduct
    $marker = Join-Path $stateRoot '.xsoc-managed-1.0.0'
    $markerHash = (Get-FileHash -LiteralPath $marker).Hash
    $configHash = (Get-FileHash -LiteralPath (Join-Path $stateRoot 'config.json')).Hash
    # This deliberate Type19 failure is only in the temporary database copy.
    # The release package and production helper have no fault-injection action.
    $failureLog = Join-Path $logs 'component-transition-rollback.log'
    $failureArguments = '/i "{0}" /qn /norestart /l*v "{1}"' -f $failedUpgrade, $failureLog
    $result = Start-Process msiexec.exe -ArgumentList $failureArguments -Wait -PassThru
    if ($result.ExitCode -ne 1603 -or
        -not (Select-String -LiteralPath $failureLog -SimpleMatch 'XSOC fixture abort after old product removal' -Quiet)) {
        throw 'Component transition fixture did not abort at the intended point.'
    }
    Assert-ComponentTransitionArtifactsAbsent 'Controlled component-transition rollback' $baselineVersion
    if ([Xsoc.MsiNativeMethods]::MsiQueryProductState($baselineProduct) -ne 5 -or
        [Xsoc.MsiNativeMethods]::MsiQueryProductState($ProductCode) -ne -1) {
        throw 'Failed same-family upgrade did not restore the old product registration.'
    }
    Assert-MsiComponentClient $foreignComponentGuids[0] $baselineProduct (Join-Path $installedRoot 'xsoc.exe')
    Assert-MsiComponentClient $foreignComponentGuids[1] $baselineProduct
    foreach ($id in @('ClientServiceComponent', 'ClientStateDirectoryComponent')) {
        if (@(Get-MsiComponentClients $xsocComponentGuids[$id]).Count -ne 0) { throw 'Failed upgrade retained a replacement component client.' }
    }
    if (-not (Get-Service xsoc -ErrorAction Stop) -or
        (Get-FileHash -LiteralPath $marker).Hash -ne $markerHash -or
        (Get-FileHash -LiteralPath (Join-Path $stateRoot 'config.json')).Hash -ne $configHash) {
        throw 'Failed same-family upgrade did not restore the old service and state.'
    }
    Invoke-Msi /i $CurrentMsi 'component-transition-upgrade'
    Assert-ComponentTransitionArtifactsAbsent 'Component-transition upgrade' $baselineVersion
    Assert-XsocComponentRegistration $ProductCode
    Assert-ArpVersion $ProductVersion
    if ([Xsoc.MsiNativeMethods]::MsiQueryProductState($baselineProduct) -ne -1) { throw 'Successful upgrade retained the old product registration.' }
    foreach ($guid in $foreignComponentGuids) {
        if (@(Get-MsiComponentClients $guid).Count -ne 0) { throw 'Successful upgrade retained an old-identity component client.' }
    }
    if ((Get-FileHash -LiteralPath $marker).Hash -ne $markerHash -or
        (Get-FileHash -LiteralPath (Join-Path $stateRoot 'config.json')).Hash -ne $configHash) {
        throw 'Component identity transition changed retained current-format state.'
    }
    Invoke-Msi /i $CurrentMsi 'component-transition-repair' 'REINSTALL=ALL REINSTALLMODE=amus'
    Assert-ComponentTransitionArtifactsAbsent 'Component-transition repair' $baselineVersion
    Assert-XsocComponentRegistration $ProductCode
    Invoke-Msi /x $CurrentMsi 'component-transition-purge' 'PURGE=1'
    Assert-ClientCompletelyAbsent
    Assert-XsocComponentRegistrationAbsent $ProductCode
    Assert-ComponentTransitionArtifactsAbsent 'Component-transition purge' $baselineVersion
    Write-Host 'Synthetic current-source MSI verified old-identity removal, failed-upgrade rollback, upgrade and repair.'
}
