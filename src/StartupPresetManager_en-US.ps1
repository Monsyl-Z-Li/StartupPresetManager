#requires -Version 5.1
<#
 StartupPresetManager
 A local Windows desktop utility for reviewing and applying startup preferences.
 It never sends inventory data off the computer.
#>

param(
    [switch]$SelfTest,
    [switch]$UiSmokeTest
)

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $args = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $args
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type @'
using System;
using System.ComponentModel;

public class StartupItem : INotifyPropertyChanged
{
    private bool _enabled;
    public string Id { get; set; }
    public string Name { get; set; }
    public string Source { get; set; }
    public string Trigger { get; set; }
    public string Command { get; set; }
    public string Details { get; set; }
    public string Kind { get; set; }
    public bool OriginalEnabled { get; set; }
    public bool IsAdvanced { get; set; }
    public bool RequiresAdmin { get; set; }
    public object Data { get; set; }
    public bool Enabled {
        get { return _enabled; }
        set { if (_enabled != value) { _enabled = value; OnPropertyChanged("Enabled"); OnPropertyChanged("Changed"); } }
    }
    public bool Changed { get { return Enabled != OriginalEnabled; } }
    public event PropertyChangedEventHandler PropertyChanged;
    private void OnPropertyChanged(string name) {
        var handler = PropertyChanged;
        if (handler != null) handler(this, new PropertyChangedEventArgs(name));
    }
}
'@

$script:AppDirectory = Join-Path $env:LOCALAPPDATA 'StartupPresetManager'
$script:DisabledFolderDirectory = Join-Path $script:AppDirectory 'DisabledStartupFolderItems'
$script:SettingsPath = Join-Path $script:AppDirectory 'settings.json'
New-Item -ItemType Directory -Path $script:AppDirectory, $script:DisabledFolderDirectory -Force | Out-Null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-DefaultSettings {
    return [pscustomobject]@{
        DisabledStartupFolderItems = @()
        ManagedItems = [pscustomobject]@{}
        Presets = [pscustomobject]@{}
    }
}

function Read-Settings {
    $settings = New-DefaultSettings
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $loaded = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $loaded.DisabledStartupFolderItems) { $settings.DisabledStartupFolderItems = @($loaded.DisabledStartupFolderItems) }
            if ($null -ne $loaded.ManagedItems) { $settings.ManagedItems = $loaded.ManagedItems }
            if ($null -ne $loaded.Presets) { $settings.Presets = $loaded.Presets }
        } catch {
            [System.Windows.MessageBox]::Show("Settings could not be read. Empty settings will be used.`n$($_.Exception.Message)", 'Startup Preset Manager') | Out-Null
        }
    }
    return $settings
}

function Save-Settings {
    $script:Settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Get-ObjectPropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-ObjectPropertyValue($Object, [string]$Name, $Value) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value }
    else { $property.Value = $Value }
}

function Remove-ObjectProperty($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { $Object.PSObject.Properties.Remove($Name) }
}

function Get-ItemId([string]$Prefix, [string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 20)
        return "${Prefix}:$hash"
    } finally { $sha.Dispose() }
}

function New-ItemModel {
    param(
        [string]$Id, [string]$Name, [string]$Source, [string]$Trigger, [string]$Command,
        [string]$Details, [string]$Kind, [bool]$Enabled, [bool]$Advanced, [bool]$RequiresAdmin, $Data
    )
    $item = [StartupItem]::new()
    $item.Id = $Id; $item.Name = $Name; $item.Source = $Source; $item.Trigger = $Trigger
    $item.Command = $Command; $item.Details = $Details; $item.Kind = $Kind
    $item.OriginalEnabled = $Enabled; $item.Enabled = $Enabled; $item.IsAdvanced = $Advanced
    $item.RequiresAdmin = $RequiresAdmin; $item.Data = $Data
    return $item
}

function Get-ApprovalSubKey([string]$Hive, [string]$RunSubKey) {
    $suffix = if ($RunSubKey -match 'WOW6432Node') { 'Run32' } else { 'Run' }
    return "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$suffix"
}

function Get-RegistryApproval([Microsoft.Win32.RegistryHive]$Hive, [string]$ApprovalSubKey, [string]$ValueName) {
    try {
        $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Default).OpenSubKey($ApprovalSubKey)
        if ($null -eq $key) { return $null }
        try {
            $bytes = $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($bytes -is [byte[]]) {
                if ($bytes[0] -eq 2) { return $true }
                if ($bytes[0] -eq 3) { return $false }
            }
        } finally { $key.Dispose() }
    } catch { }
    return $null
}

function Set-RegistryApproval([Microsoft.Win32.RegistryHive]$Hive, [string]$ApprovalSubKey, [string]$ValueName, [bool]$Enabled) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, [Microsoft.Win32.RegistryView]::Default)
    try {
        $key = $base.CreateSubKey($ApprovalSubKey)
        try {
            $state = if ($Enabled) { 2 } else { 3 }
            [byte[]]$bytes = @($state, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            $key.SetValue($ValueName, $bytes, [Microsoft.Win32.RegistryValueKind]::Binary)
        } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}

function Test-ThirdPartyRegistryCommand([string]$Command, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    if ($Name -match '^(MicrosoftEdge|WindowsDefender|SecurityHealth)') { return $false }
    if ($Command -match '(?i)\\Microsoft\\|MicrosoftEdge|msedge') { return $false }
    return $true
}

function Get-RegistryStartupItems {
    $locations = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; Label = 'HKCU'; SubKey = 'Software\Microsoft\Windows\CurrentVersion\Run'; IsMachine = $false },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; Label = 'HKCU'; SubKey = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'; IsMachine = $false },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Label = 'HKLM'; SubKey = 'Software\Microsoft\Windows\CurrentVersion\Run'; IsMachine = $true },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Label = 'HKLM'; SubKey = 'Software\Microsoft\Windows\CurrentVersion\RunOnce'; IsMachine = $true },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Label = 'HKLM (32-bit)'; SubKey = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; IsMachine = $true },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Label = 'HKLM (32-bit)'; SubKey = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; IsMachine = $true }
    )
    foreach ($location in $locations) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($location.Hive, [Microsoft.Win32.RegistryView]::Default)
        try {
            $key = $base.OpenSubKey($location.SubKey)
            if ($null -eq $key) { continue }
            try {
                $approval = Get-ApprovalSubKey $location.Label $location.SubKey
                foreach ($name in $key.GetValueNames()) {
                    $command = [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if (-not (Test-ThirdPartyRegistryCommand $command $name)) { continue }
                    $state = Get-RegistryApproval $location.Hive $approval $name
                    if ($null -eq $state) { $state = $true }
                    $runOnce = $location.SubKey -match 'RunOnce'
                    $details = if ($runOnce) { 'One-time startup entry. Windows may remove it after it runs.' } else { 'Registry startup entry at sign-in.' }
                    $data = [pscustomobject]@{ Hive = $location.Hive.ToString(); ApprovalSubKey = $approval; ValueName = $name }
                    $id = Get-ItemId 'registry' "$($location.Hive):$($location.SubKey):$name"
                    New-ItemModel $id $name $location.Label 'At sign-in' $command $details 'Registry' $state $false $location.IsMachine $data
                }
            } finally { $key.Dispose() }
        } finally { $base.Dispose() }
    }
}

function Get-ShortcutCommand([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -ne '.lnk') { return $Path }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        return ('"{0}" {1}' -f $shortcut.TargetPath, $shortcut.Arguments).Trim()
    } catch { return $Path }
}

function Get-StartupFolderItems {
    $folders = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))
    $knownOriginalPaths = @{}
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -Force -File | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            $knownOriginalPaths[$_.FullName] = $true
            $id = Get-ItemId 'startup-folder' $_.FullName
            $data = [pscustomobject]@{ OriginalPath = $_.FullName; DisabledPath = $null }
            New-ItemModel $id $_.BaseName 'Startup folder' 'At sign-in' (Get-ShortcutCommand $_.FullName) 'Shortcut or program in a startup folder.' 'StartupFolder' $true $false ($folder -eq [Environment]::GetFolderPath('CommonStartup')) $data
        }
    }
    foreach ($record in @($script:Settings.DisabledStartupFolderItems)) {
        if ($null -eq $record -or -not (Test-Path -LiteralPath $record.DisabledPath)) { continue }
        if ($knownOriginalPaths.ContainsKey([string]$record.OriginalPath)) { continue }
        $id = Get-ItemId 'startup-folder' ([string]$record.OriginalPath)
        $data = [pscustomobject]@{ OriginalPath = [string]$record.OriginalPath; DisabledPath = [string]$record.DisabledPath }
        New-ItemModel $id ([IO.Path]::GetFileNameWithoutExtension([string]$record.OriginalPath)) 'Startup folder' 'At sign-in' (Get-ShortcutCommand $record.DisabledPath) 'Startup folder item staged by this app.' 'StartupFolder' $false $false ($record.OriginalPath -like "$([Environment]::GetFolderPath('CommonStartup'))*") $data
    }
}

function Get-ScheduledStartupItems {
    try { $tasks = Get-ScheduledTask -ErrorAction Stop } catch { return }
    foreach ($task in $tasks) {
        if ($task.TaskPath -like '\Microsoft\*') { continue }
        $triggerTypes = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
        if (-not ($triggerTypes -match 'LogonTrigger|BootTrigger')) { continue }
        $actions = @($task.Actions | ForEach-Object { ('{0} {1}' -f $_.Execute, $_.Arguments).Trim() }) -join ' | '
        $enabled = [bool]$task.Settings.Enabled
        $trigger = if ($triggerTypes -match 'BootTrigger') { 'At boot' } else { 'At sign-in' }
        $data = [pscustomobject]@{ TaskName = $task.TaskName; TaskPath = $task.TaskPath }
        $id = Get-ItemId 'task' "$($task.TaskPath)$($task.TaskName)"
        New-ItemModel $id $task.TaskName 'Scheduled task' $trigger $actions 'Non-Microsoft scheduled task.' 'ScheduledTask' $enabled $false $true $data
    }
}

function Get-ExecutablePath([string]$CommandLine) {
    if ($CommandLine -match '^\s*"([^"]+\.(exe|sys))"') { return $Matches[1] }
    if ($CommandLine -match '^\s*([^\s]+\.(exe|sys))') { return $Matches[1] }
    return $null
}

function Test-ThirdPartyService($Service) {
    $path = [string]$Service.PathName
    if ($Service.Name -eq 'Wallpaper Engine Service') { return $true }
    if ($path -match '(?i)WindowsApps\\Microsoft\.|\\Microsoft GameInput\\|MicrosoftPCManager|GamingServices') { return $false }
    $exe = Get-ExecutablePath $path
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        $company = (Get-Item -LiteralPath $exe).VersionInfo.CompanyName
        if ($company -match '(?i)Microsoft') { return $false }
    }
    if ($path -match '(?i)^\s*(%SystemRoot%|C:\\Windows\\System32)') { return $false }
    return -not [string]::IsNullOrWhiteSpace($path)
}

function Get-ManagedRecord([string]$Id) { return Get-ObjectPropertyValue $script:Settings.ManagedItems $Id }

function Get-ServiceStartupItems {
    $managed = @{}
    foreach ($property in $script:Settings.ManagedItems.PSObject.Properties) {
        if ($property.Value.Kind -eq 'Service') { $managed[$property.Value.Name] = $true }
    }
    foreach ($service in Get-CimInstance Win32_Service) {
        $managedService = $managed.ContainsKey($service.Name)
        if ($service.StartMode -ne 'Auto' -and -not $managedService) { continue }
        if (-not (Test-ThirdPartyService $service)) { continue }
        $isEnabled = $service.StartMode -eq 'Auto'
        $company = $null; $exe = Get-ExecutablePath $service.PathName
        if ($exe -and (Test-Path -LiteralPath $exe)) { $company = (Get-Item -LiteralPath $exe).VersionInfo.CompanyName }
        $details = if ($company) { "Publisher: $company; current state: $($service.State)" } else { "Current state: $($service.State)" }
        $id = Get-ItemId 'service' $service.Name
        $data = [pscustomobject]@{ Name = $service.Name; OriginalStartMode = 'Auto' }
        New-ItemModel $id $service.DisplayName 'Automatic service' 'At boot' $service.PathName $details 'Service' $isEnabled $true $true $data
    }
}

function Get-DriverStartupItems {
    foreach ($driver in Get-CimInstance Win32_SystemDriver | Where-Object { $_.StartMode -eq 'Auto' }) {
        $path = [string]$driver.PathName
        $signature = $null
        $filePath = Get-ExecutablePath $path
        if ($filePath -and (Test-Path -LiteralPath $filePath)) {
            try { $signature = (Get-AuthenticodeSignature -LiteralPath $filePath).SignerCertificate.Subject } catch { }
        }
        if ($signature -match '(?i)Microsoft') { continue }
        if ($driver.Name -notmatch '(?i)signalrgb|nvidia|realtek|wireguard|vgk|easyanticheat') { continue }
        $id = Get-ItemId 'driver' $driver.Name
        $data = [pscustomobject]@{ Name = $driver.Name; OriginalStartMode = 'Auto' }
        New-ItemModel $id $driver.DisplayName 'Driver' 'At boot' $path "Hardware-level component. $signature" 'Driver' $true $true $true $data
    }
}

function Get-AllStartupItems {
    $results = New-Object 'System.Collections.ObjectModel.ObservableCollection[StartupItem]'
    @(Get-RegistryStartupItems) + @(Get-StartupFolderItems) + @(Get-ScheduledStartupItems) + @(Get-ServiceStartupItems) + @(Get-DriverStartupItems) |
        Sort-Object Name, Source | ForEach-Object { [void]$results.Add($_) }
    return $results
}

function Save-ManagedItem($Item) {
    $record = [pscustomobject]@{ Kind = $Item.Kind; Name = $Item.Data.Name; UpdatedAt = (Get-Date).ToString('o') }
    Set-ObjectPropertyValue $script:Settings.ManagedItems $Item.Id $record
}

function Set-StartupFolderItem($Item, [bool]$Enabled) {
    $original = [string]$Item.Data.OriginalPath
    $disabled = [string]$Item.Data.DisabledPath
    if ($Enabled) {
        if (-not (Test-Path -LiteralPath $disabled)) { throw "The staged startup file could not be found: $disabled" }
        New-Item -ItemType Directory -Path (Split-Path -Parent $original) -Force | Out-Null
        Move-Item -LiteralPath $disabled -Destination $original -ErrorAction Stop
        $script:Settings.DisabledStartupFolderItems = @($script:Settings.DisabledStartupFolderItems | Where-Object { $_.OriginalPath -ne $original })
    } else {
        if (-not (Test-Path -LiteralPath $original)) { throw "The startup file could not be found: $original" }
        $destination = Join-Path $script:DisabledFolderDirectory ((Get-ItemId 'file' $original).Replace(':', '_') + '_' + [IO.Path]::GetFileName($original))
        Move-Item -LiteralPath $original -Destination $destination -ErrorAction Stop
        $record = [pscustomobject]@{ OriginalPath = $original; DisabledPath = $destination }
        $script:Settings.DisabledStartupFolderItems = @($script:Settings.DisabledStartupFolderItems | Where-Object { $_.OriginalPath -ne $original }) + @($record)
    }
}

function Invoke-ScConfig([string]$Name, [string]$StartType) {
    $process = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList @('config', $Name, "start=", $StartType) -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) { throw "The service control command returned exit code $($process.ExitCode)." }
}

function Apply-StartupItem($Item) {
    switch ($Item.Kind) {
        'Registry' {
            $hive = [Microsoft.Win32.RegistryHive]([string]$Item.Data.Hive)
            Set-RegistryApproval $hive $Item.Data.ApprovalSubKey $Item.Data.ValueName $Item.Enabled
        }
        'StartupFolder' { Set-StartupFolderItem $Item $Item.Enabled }
        'ScheduledTask' {
            if ($Item.Enabled) { Enable-ScheduledTask -TaskName $Item.Data.TaskName -TaskPath $Item.Data.TaskPath -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -TaskName $Item.Data.TaskName -TaskPath $Item.Data.TaskPath -ErrorAction Stop | Out-Null }
        }
        'Service' {
            $startType = if ($Item.Enabled) { 'auto' } else { 'disabled' }
            Invoke-ScConfig $Item.Data.Name $startType
            Save-ManagedItem $Item
        }
        'Driver' {
            $startType = if ($Item.Enabled) { 'auto' } else { 'disabled' }
            Invoke-ScConfig $Item.Data.Name $startType
            Save-ManagedItem $Item
        }
        default { throw "Unknown item type: $($Item.Kind)" }
    }
}

$script:Settings = Read-Settings

if ($SelfTest) {
    $selfTestItems = Get-AllStartupItems
    $selfTestItems | Group-Object Source | Select-Object Name, Count | Format-Table -AutoSize
    exit 0
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Startup Preset Manager" Width="1120" Height="700" MinWidth="860" MinHeight="520"
        WindowStartupLocation="CenterScreen" Background="#F7F7FA">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Padding" Value="12,6"/></Style>
  </Window.Resources>
  <DockPanel Margin="18">
    <StackPanel DockPanel.Dock="Top">
      <TextBlock Text="Startup Preset Manager" FontSize="24" FontWeight="SemiBold" Foreground="#202124"/>
      <TextBlock Text="Use the checkbox to control what starts at the next sign-in or boot. Changes do not close running apps." Margin="0,4,0,14" Foreground="#5F6368"/>
      <WrapPanel Margin="0,0,0,10">
        <TextBlock Text="Preset:" VerticalAlignment="Center" Margin="0,0,5,0"/>
        <ComboBox x:Name="PresetBox" Width="180" Height="30" Margin="0,0,8,0"/>
        <Button x:Name="LoadPresetButton" Content="Load preset"/>
        <TextBox x:Name="PresetNameBox" Width="150" Height="30" VerticalContentAlignment="Center" ToolTip="Enter a new preset name"/>
        <Button x:Name="SavePresetButton" Content="Save current state"/>
        <Button x:Name="DeletePresetButton" Content="Delete preset"/>
      </WrapPanel>
      <WrapPanel Margin="0,0,0,10">
        <TextBox x:Name="SearchBox" Width="270" Height="30" VerticalContentAlignment="Center" ToolTip="Search by name, source, or command"/>
        <CheckBox x:Name="AdvancedBox" Content="Show advanced items (services and drivers)" Margin="14,6,16,0"/>
        <Button x:Name="RefreshButton" Content="Rescan"/>
        <Button x:Name="AdminButton" Content="Restart as administrator"/>
        <Button x:Name="ApplyButton" Content="Apply changes" Background="#1967D2" Foreground="White"/>
      </WrapPanel>
    </StackPanel>
    <StatusBar DockPanel.Dock="Bottom" Margin="0,10,0,0"><TextBlock x:Name="StatusText" Text="Preparing..."/></StatusBar>
    <DataGrid x:Name="ItemsGrid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
              IsReadOnly="False" SelectionMode="Single" GridLinesVisibility="Horizontal" Background="White" BorderBrush="#DADCE0">
      <DataGrid.Columns>
        <DataGridCheckBoxColumn Header="Enabled" Binding="{Binding Enabled, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="65"/>
        <DataGridTextColumn Header="Item" Binding="{Binding Name}" IsReadOnly="True" Width="190"/>
        <DataGridTextColumn Header="Source" Binding="{Binding Source}" IsReadOnly="True" Width="120"/>
        <DataGridTextColumn Header="Trigger" Binding="{Binding Trigger}" IsReadOnly="True" Width="90"/>
        <DataGridTextColumn Header="Command / details" Binding="{Binding Command}" IsReadOnly="True" Width="*"/>
        <DataGridTextColumn Header="Admin" Binding="{Binding RequiresAdmin}" IsReadOnly="True" Width="55"/>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@

$reader = New-Object Xml.XmlNodeReader $xaml
$script:Window = [Windows.Markup.XamlReader]::Load($reader)
$script:Grid = $script:Window.FindName('ItemsGrid')
$script:StatusText = $script:Window.FindName('StatusText')
$script:SearchBox = $script:Window.FindName('SearchBox')
$script:AdvancedBox = $script:Window.FindName('AdvancedBox')
$script:PresetBox = $script:Window.FindName('PresetBox')

function Update-PresetBox {
    $selected = [string]$script:PresetBox.SelectedItem
    $script:PresetBox.Items.Clear()
    foreach ($name in @($script:Settings.Presets.PSObject.Properties.Name | Sort-Object)) { [void]$script:PresetBox.Items.Add($name) }
    if ($selected -and $script:PresetBox.Items.Contains($selected)) { $script:PresetBox.SelectedItem = $selected }
}

function Update-View {
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Items)
    $filterText = $script:SearchBox.Text.Trim()
    $showAdvanced = [bool]$script:AdvancedBox.IsChecked
    $view.Filter = [Predicate[object]]{
        param($item)
        if (-not $showAdvanced -and $item.IsAdvanced) { return $false }
        if ([string]::IsNullOrWhiteSpace($filterText)) { return $true }
        return (($item.Name + ' ' + $item.Source + ' ' + $item.Command + ' ' + $item.Details) -match [regex]::Escape($filterText))
    }
    $view.Refresh()
    $visible = @($view | Measure-Object).Count
    $script:StatusText.Text = "Found $($script:Items.Count) items; showing $visible. $(if (Test-IsAdministrator) {'Running as administrator.'} else {'Some system-level items require administrator rights.'})"
}

function Refresh-Items {
    $script:StatusText.Text = 'Scanning startup locations...'
    try {
        $script:Items = Get-AllStartupItems
        $script:Grid.ItemsSource = $script:Items
        Update-View
    } catch {
        $script:StatusText.Text = "Scan failed: $($_.Exception.Message)"
    }
}

function Save-CurrentPreset {
    $name = $script:Window.FindName('PresetNameBox').Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        [System.Windows.MessageBox]::Show('Enter a preset name first.', 'Startup Preset Manager') | Out-Null; return
    }
    if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        [System.Windows.MessageBox]::Show('The preset name contains unsupported characters.', 'Startup Preset Manager') | Out-Null; return
    }
    $entries = @($script:Items | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Enabled = $_.Enabled } })
    Set-ObjectPropertyValue $script:Settings.Presets $name ([pscustomobject]@{ CreatedAt = (Get-Date).ToString('o'); Items = $entries })
    Save-Settings; Update-PresetBox; $script:PresetBox.SelectedItem = $name
    $script:StatusText.Text = "Saved preset: ${name}."
}

function Load-SelectedPreset {
    $name = [string]$script:PresetBox.SelectedItem
    if ([string]::IsNullOrWhiteSpace($name)) { [System.Windows.MessageBox]::Show('Select a preset first.', 'Startup Preset Manager') | Out-Null; return }
    $preset = Get-ObjectPropertyValue $script:Settings.Presets $name
    $states = @{}; foreach ($entry in @($preset.Items)) { $states[$entry.Id] = [bool]$entry.Enabled }
    $matched = 0
    foreach ($item in $script:Items) { if ($states.ContainsKey($item.Id)) { $item.Enabled = $states[$item.Id]; $matched++ } }
    Update-View
    $script:StatusText.Text = "Loaded preset ${name}: matched $matched of $($states.Count) items. Click Apply changes to make it effective."
}

function Apply-Changes {
    $changes = @($script:Items | Where-Object { $_.Changed })
    if ($changes.Count -eq 0) { $script:StatusText.Text = 'There are no pending changes.'; return }
    $drivers = @($changes | Where-Object { $_.Kind -eq 'Driver' })
    if ($drivers.Count -gt 0) {
        $answer = [System.Windows.MessageBox]::Show("Driver changes take effect at the next boot and can affect hardware, lighting, or networking.`nContinue?", 'Confirm advanced changes', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    $needsAdmin = @($changes | Where-Object { $_.RequiresAdmin })
    if ($needsAdmin.Count -gt 0 -and -not (Test-IsAdministrator)) {
        [System.Windows.MessageBox]::Show("$($needsAdmin.Count) change(s) require administrator rights. Click Restart as administrator, then apply the changes again.", 'Administrator rights required', 'OK', 'Information') | Out-Null
        return
    }
    $success = 0; $errors = New-Object Collections.Generic.List[string]
    foreach ($item in $changes) {
        try {
            Apply-StartupItem $item
            $item.OriginalEnabled = $item.Enabled
            $success++
        } catch { $errors.Add("$($item.Name)：$($_.Exception.Message)") }
    }
    try { Save-Settings } catch { $errors.Add("Saving settings: $($_.Exception.Message)") }
    if ($errors.Count -eq 0) {
        $script:StatusText.Text = "Applied $success change(s). Most changes take effect at the next sign-in or boot."
    } else {
        [System.Windows.MessageBox]::Show("Applied $success change(s). The following items could not be completed:`n`n$($errors -join "`n")", 'Some changes were not completed', 'OK', 'Warning') | Out-Null
        $script:StatusText.Text = "Applied $success change(s); $($errors.Count) failed."
    }
}

$script:Window.FindName('RefreshButton').Add_Click({ Refresh-Items })
$script:Window.FindName('ApplyButton').Add_Click({ Apply-Changes })
$script:Window.FindName('SavePresetButton').Add_Click({ Save-CurrentPreset })
$script:Window.FindName('LoadPresetButton').Add_Click({ Load-SelectedPreset })
$script:Window.FindName('DeletePresetButton').Add_Click({
    $name = [string]$script:PresetBox.SelectedItem
    if (-not $name) { return }
    if ([System.Windows.MessageBox]::Show("Delete preset ${name}?", 'Delete preset', 'YesNo', 'Question') -eq 'Yes') {
        Remove-ObjectProperty $script:Settings.Presets $name; Save-Settings; Update-PresetBox
    }
})
$script:SearchBox.Add_TextChanged({ Update-View })
$script:AdvancedBox.Add_Click({ Update-View })
$script:Grid.Add_SelectionChanged({
    $item = $script:Grid.SelectedItem
    if ($null -ne $item) { $script:StatusText.Text = "$($item.Details)$(if ($item.RequiresAdmin) {'  Changing this item requires administrator rights.'})" }
})
$script:Window.FindName('AdminButton').Add_Click({
    if (Test-IsAdministrator) { $script:StatusText.Text = 'The app is already running as administrator.'; return }
    try {
        $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
        $script:Window.Close()
    } catch { [System.Windows.MessageBox]::Show("Could not restart as administrator: $($_.Exception.Message)", 'Startup Preset Manager') | Out-Null }
})

Update-PresetBox
Refresh-Items
if ($UiSmokeTest) { exit 0 }
[void]$script:Window.ShowDialog()

