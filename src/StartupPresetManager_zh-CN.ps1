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
            [System.Windows.MessageBox]::Show("无法读取设置文件，将使用空设置。`n$($_.Exception.Message)", '启动配置管理器') | Out-Null
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
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Label = 'HKLM (32 位)'; SubKey = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; IsMachine = $true },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; Label = 'HKLM (32 位)'; SubKey = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; IsMachine = $true }
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
                    $details = if ($runOnce) { '一次性启动项：启动后系统可能自动删除它。' } else { '注册表登录启动项。' }
                    $data = [pscustomobject]@{ Hive = $location.Hive.ToString(); ApprovalSubKey = $approval; ValueName = $name }
                    $id = Get-ItemId 'registry' "$($location.Hive):$($location.SubKey):$name"
                    New-ItemModel $id $name $location.Label '登录时' $command $details 'Registry' $state $false $location.IsMachine $data
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
            New-ItemModel $id $_.BaseName '启动文件夹' '登录时' (Get-ShortcutCommand $_.FullName) '启动文件夹中的快捷方式或程序。' 'StartupFolder' $true $false ($folder -eq [Environment]::GetFolderPath('CommonStartup')) $data
        }
    }
    foreach ($record in @($script:Settings.DisabledStartupFolderItems)) {
        if ($null -eq $record -or -not (Test-Path -LiteralPath $record.DisabledPath)) { continue }
        if ($knownOriginalPaths.ContainsKey([string]$record.OriginalPath)) { continue }
        $id = Get-ItemId 'startup-folder' ([string]$record.OriginalPath)
        $data = [pscustomobject]@{ OriginalPath = [string]$record.OriginalPath; DisabledPath = [string]$record.DisabledPath }
        New-ItemModel $id ([IO.Path]::GetFileNameWithoutExtension([string]$record.OriginalPath)) '启动文件夹' '登录时' (Get-ShortcutCommand $record.DisabledPath) '由本工具移出的启动文件夹项目。' 'StartupFolder' $false $false ($record.OriginalPath -like "$([Environment]::GetFolderPath('CommonStartup'))*") $data
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
        $trigger = if ($triggerTypes -match 'BootTrigger') { '开机时' } else { '登录时' }
        $data = [pscustomobject]@{ TaskName = $task.TaskName; TaskPath = $task.TaskPath }
        $id = Get-ItemId 'task' "$($task.TaskPath)$($task.TaskName)"
        New-ItemModel $id $task.TaskName '计划任务' $trigger $actions '非 Microsoft 计划任务。' 'ScheduledTask' $enabled $false $true $data
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
        $details = if ($company) { "发布者：$company；当前状态：$($service.State)" } else { "当前状态：$($service.State)" }
        $id = Get-ItemId 'service' $service.Name
        $data = [pscustomobject]@{ Name = $service.Name; OriginalStartMode = 'Auto' }
        New-ItemModel $id $service.DisplayName '自动服务' '开机时' $service.PathName $details 'Service' $isEnabled $true $true $data
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
        New-ItemModel $id $driver.DisplayName '驱动程序' '开机时' $path "硬件级组件。$signature" 'Driver' $true $true $true $data
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
        if (-not (Test-Path -LiteralPath $disabled)) { throw "找不到被暂存的启动文件：$disabled" }
        New-Item -ItemType Directory -Path (Split-Path -Parent $original) -Force | Out-Null
        Move-Item -LiteralPath $disabled -Destination $original -ErrorAction Stop
        $script:Settings.DisabledStartupFolderItems = @($script:Settings.DisabledStartupFolderItems | Where-Object { $_.OriginalPath -ne $original })
    } else {
        if (-not (Test-Path -LiteralPath $original)) { throw "找不到启动文件：$original" }
        $destination = Join-Path $script:DisabledFolderDirectory ((Get-ItemId 'file' $original).Replace(':', '_') + '_' + [IO.Path]::GetFileName($original))
        Move-Item -LiteralPath $original -Destination $destination -ErrorAction Stop
        $record = [pscustomobject]@{ OriginalPath = $original; DisabledPath = $destination }
        $script:Settings.DisabledStartupFolderItems = @($script:Settings.DisabledStartupFolderItems | Where-Object { $_.OriginalPath -ne $original }) + @($record)
    }
}

function Invoke-ScConfig([string]$Name, [string]$StartType) {
    $process = Start-Process -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList @('config', $Name, "start=", $StartType) -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) { throw "服务控制命令返回错误码 $($process.ExitCode)。" }
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
        default { throw "未知项目类型：$($Item.Kind)" }
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
        Title="启动配置管理器" Width="1120" Height="700" MinWidth="860" MinHeight="520"
        WindowStartupLocation="CenterScreen" Background="#F7F7FA">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="Padding" Value="12,6"/></Style>
  </Window.Resources>
  <DockPanel Margin="18">
    <StackPanel DockPanel.Dock="Top">
      <TextBlock Text="启动配置管理器" FontSize="24" FontWeight="SemiBold" Foreground="#202124"/>
      <TextBlock Text="勾选决定下次登录或开机时是否自动启动。更改不会结束正在运行的软件。" Margin="0,4,0,14" Foreground="#5F6368"/>
      <WrapPanel Margin="0,0,0,10">
        <TextBlock Text="预设：" VerticalAlignment="Center" Margin="0,0,5,0"/>
        <ComboBox x:Name="PresetBox" Width="180" Height="30" Margin="0,0,8,0"/>
        <Button x:Name="LoadPresetButton" Content="切换预设"/>
        <TextBox x:Name="PresetNameBox" Width="150" Height="30" VerticalContentAlignment="Center" ToolTip="输入新预设名称"/>
        <Button x:Name="SavePresetButton" Content="保存当前为预设"/>
        <Button x:Name="DeletePresetButton" Content="删除预设"/>
      </WrapPanel>
      <WrapPanel Margin="0,0,0,10">
        <TextBox x:Name="SearchBox" Width="270" Height="30" VerticalContentAlignment="Center" ToolTip="按名称、来源或命令搜索"/>
        <CheckBox x:Name="AdvancedBox" Content="显示高级项目（服务、驱动）" Margin="14,6,16,0"/>
        <Button x:Name="RefreshButton" Content="重新扫描"/>
        <Button x:Name="AdminButton" Content="以管理员身份重新打开"/>
        <Button x:Name="ApplyButton" Content="应用更改" Background="#1967D2" Foreground="White"/>
      </WrapPanel>
    </StackPanel>
    <StatusBar DockPanel.Dock="Bottom" Margin="0,10,0,0"><TextBlock x:Name="StatusText" Text="正在准备…"/></StatusBar>
    <DataGrid x:Name="ItemsGrid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
              IsReadOnly="False" SelectionMode="Single" GridLinesVisibility="Horizontal" Background="White" BorderBrush="#DADCE0">
      <DataGrid.Columns>
        <DataGridCheckBoxColumn Header="启用" Binding="{Binding Enabled, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="58"/>
        <DataGridTextColumn Header="项目" Binding="{Binding Name}" IsReadOnly="True" Width="190"/>
        <DataGridTextColumn Header="来源" Binding="{Binding Source}" IsReadOnly="True" Width="100"/>
        <DataGridTextColumn Header="触发时机" Binding="{Binding Trigger}" IsReadOnly="True" Width="85"/>
        <DataGridTextColumn Header="启动命令 / 说明" Binding="{Binding Command}" IsReadOnly="True" Width="*"/>
        <DataGridTextColumn Header="权限" Binding="{Binding RequiresAdmin}" IsReadOnly="True" Width="55"/>
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
    $script:StatusText.Text = "已找到 $($script:Items.Count) 个项目；当前显示 $visible 个。$(if (Test-IsAdministrator) {'正在以管理员身份运行。'} else {'部分系统级项目需要管理员权限。'})"
}

function Refresh-Items {
    $script:StatusText.Text = '正在扫描启动入口…'
    try {
        $script:Items = Get-AllStartupItems
        $script:Grid.ItemsSource = $script:Items
        Update-View
    } catch {
        $script:StatusText.Text = "扫描失败：$($_.Exception.Message)"
    }
}

function Save-CurrentPreset {
    $name = $script:Window.FindName('PresetNameBox').Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        [System.Windows.MessageBox]::Show('请先输入预设名称。', '启动配置管理器') | Out-Null; return
    }
    if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        [System.Windows.MessageBox]::Show('预设名称包含不支持的字符。', '启动配置管理器') | Out-Null; return
    }
    $entries = @($script:Items | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Enabled = $_.Enabled } })
    Set-ObjectPropertyValue $script:Settings.Presets $name ([pscustomobject]@{ CreatedAt = (Get-Date).ToString('o'); Items = $entries })
    Save-Settings; Update-PresetBox; $script:PresetBox.SelectedItem = $name
    $script:StatusText.Text = "已保存预设【${name}】。"
}

function Load-SelectedPreset {
    $name = [string]$script:PresetBox.SelectedItem
    if ([string]::IsNullOrWhiteSpace($name)) { [System.Windows.MessageBox]::Show('请选择一个预设。', '启动配置管理器') | Out-Null; return }
    $preset = Get-ObjectPropertyValue $script:Settings.Presets $name
    $states = @{}; foreach ($entry in @($preset.Items)) { $states[$entry.Id] = [bool]$entry.Enabled }
    $matched = 0
    foreach ($item in $script:Items) { if ($states.ContainsKey($item.Id)) { $item.Enabled = $states[$item.Id]; $matched++ } }
    Update-View
    $script:StatusText.Text = "已载入【${name}】：匹配 $matched / $($states.Count) 个项目。点击【应用更改】后生效。"
}

function Apply-Changes {
    $changes = @($script:Items | Where-Object { $_.Changed })
    if ($changes.Count -eq 0) { $script:StatusText.Text = '没有待应用的更改。'; return }
    $drivers = @($changes | Where-Object { $_.Kind -eq 'Driver' })
    if ($drivers.Count -gt 0) {
        $answer = [System.Windows.MessageBox]::Show("驱动项目将在下次开机时改变加载状态，可能影响硬件、灯效或网络功能。`n确定继续吗？", '确认高级更改', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    $needsAdmin = @($changes | Where-Object { $_.RequiresAdmin })
    if ($needsAdmin.Count -gt 0 -and -not (Test-IsAdministrator)) {
        [System.Windows.MessageBox]::Show("本次有 $($needsAdmin.Count) 项需要管理员权限。请点击【以管理员身份重新打开】，然后重新应用。", '需要管理员权限', 'OK', 'Information') | Out-Null
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
    try { Save-Settings } catch { $errors.Add("保存设置：$($_.Exception.Message)") }
    if ($errors.Count -eq 0) {
        $script:StatusText.Text = "已成功应用 $success 项更改；通常在下一次登录或开机时生效。"
    } else {
        [System.Windows.MessageBox]::Show("已成功应用 $success 项。以下项目未完成：`n`n$($errors -join "`n")", '部分更改未完成', 'OK', 'Warning') | Out-Null
        $script:StatusText.Text = "已应用 $success 项，$($errors.Count) 项失败。"
    }
}

$script:Window.FindName('RefreshButton').Add_Click({ Refresh-Items })
$script:Window.FindName('ApplyButton').Add_Click({ Apply-Changes })
$script:Window.FindName('SavePresetButton').Add_Click({ Save-CurrentPreset })
$script:Window.FindName('LoadPresetButton').Add_Click({ Load-SelectedPreset })
$script:Window.FindName('DeletePresetButton').Add_Click({
    $name = [string]$script:PresetBox.SelectedItem
    if (-not $name) { return }
    if ([System.Windows.MessageBox]::Show("删除预设【${name}】？", '删除预设', 'YesNo', 'Question') -eq 'Yes') {
        Remove-ObjectProperty $script:Settings.Presets $name; Save-Settings; Update-PresetBox
    }
})
$script:SearchBox.Add_TextChanged({ Update-View })
$script:AdvancedBox.Add_Click({ Update-View })
$script:Grid.Add_SelectionChanged({
    $item = $script:Grid.SelectedItem
    if ($null -ne $item) { $script:StatusText.Text = "$($item.Details)$(if ($item.RequiresAdmin) {'  修改此项需要管理员权限。'})" }
})
$script:Window.FindName('AdminButton').Add_Click({
    if (Test-IsAdministrator) { $script:StatusText.Text = '当前已经以管理员身份运行。'; return }
    try {
        $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
        $script:Window.Close()
    } catch { [System.Windows.MessageBox]::Show("无法以管理员身份重新打开：$($_.Exception.Message)", '启动配置管理器') | Out-Null }
})

Update-PresetBox
Refresh-Items
if ($UiSmokeTest) { exit 0 }
[void]$script:Window.ShowDialog()

