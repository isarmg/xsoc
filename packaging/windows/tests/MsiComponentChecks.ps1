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
        $components = @(Read-MsiRows $database 'SELECT `Component`, `ComponentId`, `Attributes`, `KeyPath` FROM `Component`' @('Id', 'Guid', 'Attributes', 'KeyPath'))
        if ($components.Count -ne $xsocComponentGuids.Count) { throw 'Unexpected compiled MSI component set.' }
        foreach ($component in $components) {
            if (-not $xsocComponentGuids.ContainsKey($component.Id) -or
                $component.Guid -ne $xsocComponentGuids[$component.Id] -or
                ([int]$component.Attributes -band 256) -eq 0) {
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
    $fixturePayload = Join-Path $repositoryRoot 'target\x86_64-pc-windows-msvc\release\xsoc.exe'
    & dotnet build $fixtureProject -c Release "-p:ClientExe=$fixturePayload" "-p:OutputPath=$fixtureOutput"
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

function New-ComponentTransitionFixture([string]$Source, [string]$Target, [bool]$Baseline) {
    # Test-only database copies use the current compiled payload and helper.
    # They do not represent a previous binary, state format or HostMonitor.
    Copy-Item -LiteralPath $Source -Destination $Target
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Target, 1)
    try {
        $queries = @()
        if ($Baseline) {
            $version = [version]$ProductVersion
            $lowerVersion = if ($version.Build -gt 0) { "$($version.Major).$($version.Minor).$($version.Build - 1)" }
                elseif ($version.Minor -gt 0) { "$($version.Major).$($version.Minor - 1).65535" }
                elseif ($version.Major -gt 0) { "$($version.Major - 1).255.65535" }
                else { throw 'No smaller MSI version is available for the transition fixture.' }
            $queries += "UPDATE ``Property`` SET ``Value``='{E0F59096-C373-59C0-A835-FDAD36B674F0}' WHERE ``Property``='ProductCode'"
            $queries += "UPDATE ``Property`` SET ``Value``='$lowerVersion' WHERE ``Property``='ProductVersion'"
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
    New-ComponentTransitionFixture $CurrentMsi $baseline $true
    New-ComponentTransitionFixture $CurrentMsi $failedUpgrade $false
    Invoke-Msi /i $baseline 'component-transition-baseline'
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
    Assert-MaintenanceDiagnosticAbsent 'controlled component-transition rollback'
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
    Assert-XsocComponentRegistration $ProductCode
    Invoke-Msi /x $CurrentMsi 'component-transition-purge' 'PURGE=1'
    Assert-ClientCompletelyAbsent
    Assert-XsocComponentRegistrationAbsent $ProductCode
    Write-Host 'Synthetic current-payload MSI verified old-identity removal, failed-upgrade rollback, upgrade and repair.'
}
