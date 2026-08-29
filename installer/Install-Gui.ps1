<#
.SYNOPSIS
    The Heresay setup window: a graphical installer wizard for TranscribeIt.

.DESCRIPTION
    Launched hidden by "Install Heresay.vbs" as:
        powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File installer\Install-Gui.ps1 [args]

    This script runs on STOCK Windows PowerShell 5.1 and deliberately uses no
    PowerShell-7-only syntax (no ternary, no ??, no ?.). It is ONLY the window;
    the actual work stays in the same battle-tested scripts the console path uses,
    run here as hidden child processes and rendered live:

      1. installer\Bootstrap-Pwsh.ps1 under powershell.exe, when PowerShell 7 is
         absent (its "  ... 20 MB of 101 MB" lines drive the progress bar), then
      2. installer\Install-TranscribeIt.ps1 under the found pwsh 7, with
         -SourceRoot <repo root> and -DownloadCache <root>\download-cache when
         that folder ships beside the installer (mirrors Install Heresay.cmd),
         plus any arguments this script itself received, passed through verbatim
         (testers use -InstallRoot/-RegistryRoot/-Skip*/-WhatIf; users pass none).

    TI_INSTALL_GUI=1 is set on this process, so children inherit it and
    Install-Common.ps1's Invoke-TiDownload emits machine-readable
    "#TIDL|<name>|<written>|<total>" download-progress lines (throttled there).

    stdout and stderr of each child are read on dedicated background runspaces
    into a lock-free queue (a synchronous read on the UI thread would deadlock the
    child once the pipe buffer fills), and a DispatcherTimer drains that queue on
    the UI thread - so nothing here ever touches WPF off-thread and the window
    stays responsive through the ~2.7 GB download.

    Visual language is copied from app\Progress.ps1 on purpose: same fonts,
    palette, flat progress bars, runtime-drawn speech-bubble icon (no binary
    assets ship), and an explicit AppUserModelID so the taskbar shows a real
    identity instead of a bare PowerShell prompt.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {

# ------------------------------------------------------------------ environment --

# Everything this script received is passed through to Install-TranscribeIt.ps1
# verbatim. Deliberately a plain (non-advanced) script: an advanced param() block
# would reject -WhatIf instead of forwarding it.
$script:PassArgs = @()
foreach ($a in $args) { $script:PassArgs += [string]$a }

$script:InstallerDir  = $PSScriptRoot
$script:SourceRoot    = Split-Path -Parent $script:InstallerDir
$script:DownloadCache = Join-Path $script:SourceRoot 'download-cache'
$script:HasOffline    = Test-Path -LiteralPath $script:DownloadCache

# Where the install lands - only used for display and for finding the log folder.
# Honour a tester's -InstallRoot override so both point at the right place.
$script:InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\TranscribeIt'
for ($i = 0; $i -lt $script:PassArgs.Count - 1; $i++) {
    if ($script:PassArgs[$i] -eq '-InstallRoot') { $script:InstallRoot = $script:PassArgs[$i + 1] }
}

# The gate for Install-Common.ps1's #TIDL lines. Set on OUR environment so every
# child process inherits it; console installs never see it, so they are untouched.
$env:TI_INSTALL_GUI = '1'
# pwsh 7 respects NO_COLOR and renders plain text when redirected; belt and braces
# so no ANSI escapes ever reach the details pane.
$env:NO_COLOR = '1'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# --------------------------------------------------------------------- identity --

# Same trick as app\Progress.ps1: without an explicit AppUserModelID the taskbar
# groups this window under powershell.exe and shows its icon, which looks like
# something went wrong on a corporate laptop. A failure costs the identity only.
try {
    if (-not ('TranscribeIt.Setup.AppUserModelId' -as [Type])) {
        Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System.Runtime.InteropServices;

namespace TranscribeIt.Setup
{
    public static class AppUserModelId
    {
        [DllImport("shell32.dll", ExactSpelling = true)]
        public static extern int SetCurrentProcessExplicitAppUserModelID(
            [MarshalAs(UnmanagedType.LPWStr)] string appId);
    }
}
'@
    }
    [void][TranscribeIt.Setup.AppUserModelId]::SetCurrentProcessExplicitAppUserModelID('Heresay.TranscribeIt.Setup')
}
catch { }

# ---------------------------------------------------------------------- helpers --

function Format-Bytes {
    param([long] $Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Find-Pwsh7 {
    # Same order as Install Heresay.cmd and Install-Common.ps1's Find-TiPwsh
    # (minus $PSHOME, which is Windows PowerShell here): Program Files, then the
    # per-user portable copy Bootstrap-Pwsh.ps1 installs, then PATH.
    $candidates = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7\pwsh.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    $cmd = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-FreeGB {
    try {
        $root = [System.IO.Path]::GetPathRoot($script:InstallRoot)
        $di = New-Object System.IO.DriveInfo ($root)
        return [Math]::Round($di.AvailableFreeSpace / 1GB, 1)
    }
    catch { return $null }
}

function ConvertTo-ArgString {
    # .NET Framework's ProcessStartInfo has no ArgumentList, so quote by hand.
    # Only paths and plain switches pass through here; embedded quotes are escaped
    # the way the MSVCRT parser expects.
    param([string[]] $Items)
    $sb = New-Object System.Text.StringBuilder
    foreach ($it in $Items) {
        if ($sb.Length -gt 0) { [void]$sb.Append(' ') }
        if ($it -match '[\s"]' -or $it.Length -eq 0) {
            [void]$sb.Append('"' + ($it -replace '"', '\"') + '"')
        }
        else { [void]$sb.Append($it) }
    }
    return $sb.ToString()
}

# ------------------------------------------------------------------------- XAML --

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Heresay Setup" Width="560" Height="420"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#FFF6F6F6" Foreground="#FF1A1A1A"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent"    Color="#FF0067C0"/>
    <SolidColorBrush x:Key="AccentDim" Color="#FF1975C5"/>
    <SolidColorBrush x:Key="Track"     Color="#FFDCDCDC"/>
    <SolidColorBrush x:Key="Muted"     Color="#FF5F5F5F"/>
    <SolidColorBrush x:Key="Faint"     Color="#FF767676"/>
    <SolidColorBrush x:Key="Danger"    Color="#FFC42B1C"/>
    <SolidColorBrush x:Key="Warn"      Color="#FF8A5300"/>
    <SolidColorBrush x:Key="Success"   Color="#FF107C10"/>
    <SolidColorBrush x:Key="CardBg"    Color="#FFFDFDFD"/>
    <SolidColorBrush x:Key="CardEdge"  Color="#FFE3E3E3"/>

    <!-- Flat progress bar, same template as app\Progress.ps1: no gradient, no
         glow sweep, a real marquee for the indeterminate case. -->
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Background" Value="{StaticResource Track}"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid ClipToBounds="True">
              <Border Background="{TemplateBinding Background}" CornerRadius="3"/>
              <Border x:Name="PART_Track"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left"
                      Background="{TemplateBinding Foreground}" CornerRadius="3"/>
              <Border x:Name="Marquee" Width="86" HorizontalAlignment="Left"
                      Background="{TemplateBinding Foreground}" CornerRadius="3"
                      Visibility="Collapsed">
                <Border.RenderTransform>
                  <TranslateTransform x:Name="MarqueeShift" X="-86"/>
                </Border.RenderTransform>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsIndeterminate" Value="True">
                <Setter TargetName="PART_Indicator" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="Marquee" Property="Visibility" Value="Visible"/>
                <Trigger.EnterActions>
                  <BeginStoryboard Name="MarqueeStory">
                    <Storyboard RepeatBehavior="Forever">
                      <DoubleAnimation Storyboard.TargetName="MarqueeShift"
                                       Storyboard.TargetProperty="X"
                                       From="-86" To="540" Duration="0:0:1.5"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <StopStoryboard BeginStoryboardName="MarqueeStory"/>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Height" Value="30"/>
      <Setter Property="MinWidth" Value="92"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Foreground" Value="#FF1A1A1A"/>
      <Setter Property="Background" Value="#FFFDFDFD"/>
      <Setter Property="BorderBrush" Value="#FFD2D2D2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="4" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFF2F2F2"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFE9E9E9"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#FFF7F7F7"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FFE2E2E2"/>
                <Setter Property="Foreground" Value="#FFA6A6A6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Foreground" Value="#FFFFFFFF"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="4" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentDim}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF00559E"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#FF9DC3E3"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FF9DC3E3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToggleButton">
      <Setter Property="Height" Value="30"/>
      <Setter Property="MinWidth" Value="104"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Foreground" Value="#FF1A1A1A"/>
      <Setter Property="Background" Value="#FFFDFDFD"/>
      <Setter Property="BorderBrush" Value="#FFD2D2D2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    CornerRadius="4" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFF2F2F2"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFE9E9E9"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FFBFBFBF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <!-- ============================== WELCOME ============================== -->
    <Grid x:Name="PaneWelcome" Visibility="Visible">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <StackPanel Grid.Row="0" Margin="30,26,30,0">
        <StackPanel Orientation="Horizontal">
          <Image x:Name="ImgLogo" Width="46" Height="46" VerticalAlignment="Center"/>
          <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Heresay" FontSize="25" FontWeight="SemiBold"/>
            <TextBlock FontSize="12" Foreground="{StaticResource Muted}" Margin="1,1,0,0"
                       Text="Turns a recording into a transcript PDF - everything stays on this computer"/>
          </StackPanel>
        </StackPanel>

        <Border Margin="0,22,0,0" Background="{StaticResource CardBg}"
                BorderBrush="{StaticResource CardEdge}" BorderThickness="1"
                CornerRadius="6" Padding="16,13">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="98"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.Column="0" Foreground="{StaticResource Faint}" Text="Installs to"/>
            <TextBlock Grid.Row="0" Grid.Column="1" x:Name="TbLoc" TextTrimming="CharacterEllipsis"/>
            <TextBlock Grid.Row="1" Grid.Column="0" Margin="0,9,0,0" Foreground="{StaticResource Faint}" Text="Download"/>
            <TextBlock Grid.Row="1" Grid.Column="1" Margin="0,9,0,0" x:Name="TbDl" TextWrapping="Wrap"/>
            <TextBlock Grid.Row="2" Grid.Column="0" Margin="0,9,0,0" Foreground="{StaticResource Faint}" Text="Disk space"/>
            <TextBlock Grid.Row="2" Grid.Column="1" Margin="0,9,0,0" x:Name="TbDisk" TextWrapping="Wrap"/>
          </Grid>
        </Border>

        <TextBlock Margin="2,14,0,0" FontSize="11" Foreground="{StaticResource Faint}" TextWrapping="Wrap"
                   Text="Installs for your user account only. No admin rights are needed, and none are asked for."/>
      </StackPanel>
      <Border Grid.Row="1" Background="#FFFBFBFB" BorderBrush="{StaticResource CardEdge}"
              BorderThickness="0,1,0,0" Padding="22,13">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnInstall" Content="Install" IsDefault="True"
                  Style="{StaticResource AccentButton}"/>
          <Button x:Name="BtnWelcomeCancel" Content="Cancel" IsCancel="True"/>
        </StackPanel>
      </Border>
    </Grid>

    <!-- ============================== PROGRESS ============================= -->
    <Grid x:Name="PaneProgress" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid Grid.Row="0" Margin="30,26,30,10">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="TbStage" Grid.Row="0" FontSize="17" FontWeight="SemiBold"
                   TextTrimming="CharacterEllipsis" Text="Getting ready"/>
        <TextBlock x:Name="TbStatus" Grid.Row="1" Margin="0,6,0,0" FontSize="11"
                   Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis" Text=""/>
        <Grid Grid.Row="2" Margin="0,16,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <ProgressBar x:Name="BarOverall" Grid.Column="0" VerticalAlignment="Center" Value="0"/>
          <TextBlock x:Name="TbPct" Grid.Column="1" Margin="10,0,0,0" MinWidth="34" FontSize="11"
                     Foreground="{StaticResource Faint}" TextAlignment="Right"
                     VerticalAlignment="Center" Text="0%"/>
        </Grid>
        <TextBlock x:Name="TbFile" Grid.Row="3" Margin="0,14,0,0" FontSize="11"
                   Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis"
                   Visibility="Collapsed" Text=""/>
        <ProgressBar x:Name="BarFile" Grid.Row="4" Margin="0,6,44,0" Height="4"
                     Foreground="{StaticResource AccentDim}" Visibility="Collapsed" Value="0"/>
        <TextBox x:Name="TbDetails" Grid.Row="5" Margin="0,14,0,0" Visibility="Collapsed"
                 FontFamily="Consolas" FontSize="11" IsReadOnly="True" IsReadOnlyCaretVisible="False"
                 TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto" Background="#FFFFFFFF"
                 BorderBrush="{StaticResource CardEdge}" BorderThickness="1" Padding="6,4"/>
      </Grid>
      <Border Grid.Row="1" Background="#FFFBFBFB" BorderBrush="{StaticResource CardEdge}"
              BorderThickness="0,1,0,0" Padding="22,13">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <ToggleButton x:Name="BtnDetails" Grid.Column="0" Content="Show details"/>
          <Button x:Name="BtnProgressCancel" Grid.Column="2" Content="Cancel"/>
        </Grid>
      </Border>
    </Grid>

    <!-- ============================= DONE/FAILED =========================== -->
    <Grid x:Name="PaneDone" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <StackPanel Grid.Row="0" Margin="34,30,34,0">
        <StackPanel Orientation="Horizontal">
          <Image x:Name="ImgResult" Width="46" Height="46" VerticalAlignment="Center"/>
          <TextBlock x:Name="TbResultTitle" FontSize="19" FontWeight="SemiBold"
                     VerticalAlignment="Center" Margin="14,0,0,0" Text=""/>
        </StackPanel>
        <TextBlock x:Name="TbResultBody" Margin="0,18,0,0" FontSize="12"
                   TextWrapping="Wrap" LineHeight="19" Text=""/>
      </StackPanel>
      <Border Grid.Row="1" Background="#FFFBFBFB" BorderBrush="{StaticResource CardEdge}"
              BorderThickness="0,1,0,0" Padding="22,13">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="BtnOpenLog" Grid.Column="0" Margin="0" Content="Open log folder"
                  Visibility="Collapsed"/>
          <Button x:Name="BtnClose" Grid.Column="2" Content="Close" IsDefault="True"
                  Style="{StaticResource AccentButton}"/>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [System.Windows.Markup.XamlReader]::Load($reader)

$UI = @{
    Win               = $win
    PaneWelcome       = $win.FindName('PaneWelcome')
    PaneProgress      = $win.FindName('PaneProgress')
    PaneDone          = $win.FindName('PaneDone')
    ImgLogo           = $win.FindName('ImgLogo')
    TbLoc             = $win.FindName('TbLoc')
    TbDl              = $win.FindName('TbDl')
    TbDisk            = $win.FindName('TbDisk')
    BtnInstall        = $win.FindName('BtnInstall')
    BtnWelcomeCancel  = $win.FindName('BtnWelcomeCancel')
    TbStage           = $win.FindName('TbStage')
    TbStatus          = $win.FindName('TbStatus')
    BarOverall        = $win.FindName('BarOverall')
    TbPct             = $win.FindName('TbPct')
    TbFile            = $win.FindName('TbFile')
    BarFile           = $win.FindName('BarFile')
    TbDetails         = $win.FindName('TbDetails')
    BtnDetails        = $win.FindName('BtnDetails')
    BtnProgressCancel = $win.FindName('BtnProgressCancel')
    ImgResult         = $win.FindName('ImgResult')
    TbResultTitle     = $win.FindName('TbResultTitle')
    TbResultBody      = $win.FindName('TbResultBody')
    BtnOpenLog        = $win.FindName('BtnOpenLog')
    BtnClose          = $win.FindName('BtnClose')
}

# ------------------------------------------------------------------- taskbar --

$tbi = New-Object System.Windows.Shell.TaskbarItemInfo
$win.TaskbarItemInfo = $tbi

# --------------------------------------------------------------- drawn icons --
# Same runtime-drawing approach and the same speech-bubble geometry as
# app\Progress.ps1 (which mirrors installer\assets\New-AppMark.ps1) so the setup
# window carries the exact brand mark without shipping a binary asset.

function New-MediaColor {
    param([string] $hex)
    return [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
}

# Geometry mini-language is culture-invariant; never let the current locale turn
# "9.5" into "9,5" and corrupt a path string.
function Format-Invariant {
    param([string] $format, [object[]] $values)
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $format, $values)
}

function New-IconBitmap {
    param([scriptblock] $draw, [int] $size = 32)
    $visual = New-Object System.Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    try { $null = & $draw $dc $size } finally { $dc.Close() }
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap (
        $size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($visual)
    $rtb.Freeze()
    # PNG round-trip: shell interop (window icon, taskbar) is fussier about raw
    # RenderTargetBitmaps than on-screen Image elements are. Done once at startup.
    try {
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $stream = New-Object System.IO.MemoryStream
        $encoder.Save($stream)
        $stream.Position = 0
        $img = New-Object System.Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.CacheOption = 'OnLoad'
        $img.StreamSource = $stream
        $img.EndInit()
        $img.Freeze()
        $stream.Dispose()
        return $img
    }
    catch { return $rtb }
}

# Teal speech bubble with two knocked-out text lines on a slate tile - the app's
# mark, replicated from app\Progress.ps1 lines ~850-869. The {1} placeholder does
# double duty as top-edge y AND tail-end x; the numbers happen to coincide there.
$script:IconApp = New-IconBitmap {
    param($dc, $size)
    $s = $size / 32.0
    $ink    = New-Object System.Windows.Media.SolidColorBrush (New-MediaColor '#FF12333F')
    $accent = New-Object System.Windows.Media.SolidColorBrush (New-MediaColor '#FF19B0AE')
    $dc.DrawRoundedRectangle($ink, $null,
        (New-Object System.Windows.Rect (0, 0, $size, $size)), (7.0 * $s), (7.0 * $s))
    $bub = [System.Windows.Media.Geometry]::Parse((Format-Invariant `
        'M {0},{1} H {2} A {3},{3} 0 0 1 {4},{5} V {6} A {3},{3} 0 0 1 {2},{7} H {8} L {9},{10} L {11},{7} H {1} A {3},{3} 0 0 1 {12},{6} V {5} A {3},{3} 0 0 1 {0},{1} Z' @(
        (8.2*$s),(6.4*$s),(23.8*$s),(3.4*$s),(27.2*$s),(9.8*$s),(16.4*$s),(19.8*$s),
        (14.6*$s),(11.4*$s),(25.6*$s),(10.4*$s),(4.8*$s))))
    $dc.DrawGeometry($accent, $null, $bub)
    foreach ($line in @(@(9.6, 10.4, 12.6), @(9.6, 14.2, 8.4))) {
        $dc.DrawRoundedRectangle($ink, $null, (New-Object System.Windows.Rect (
            ($line[0]*$s), ($line[1]*$s), ($line[2]*$s), (2.6*$s))), (1.3*$s), (1.3*$s))
    }
} 64

function New-ResultBadge {
    # Same construction as Progress.ps1's New-BadgeIcon: filled circle, white
    # ring, white glyph. 'tick' for success, 'cross' for failure/cancel.
    param([string] $fillHex, [string] $glyph)
    return New-IconBitmap {
        param($dc, $size)
        $half = $size / 2.0
        $fill = New-Object System.Windows.Media.SolidColorBrush (New-MediaColor $fillHex)
        $white = New-Object System.Windows.Media.SolidColorBrush (New-MediaColor '#FFFFFFFF')
        $ring = New-Object System.Windows.Media.Pen ($white, ($size * 0.06))
        $dc.DrawEllipse($fill, $ring,
            (New-Object System.Windows.Point ($half, $half)), ($half * 0.94), ($half * 0.94))
        $pen = New-Object System.Windows.Media.Pen ($white, ($size * 0.11))
        $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
        $s = $size / 32.0
        if ($glyph -eq 'tick') {
            $geo = [System.Windows.Media.Geometry]::Parse((Format-Invariant 'M {0},{1} L {2},{3} L {4},{5}' @(
                (9*$s),(17*$s),(14*$s),(22*$s),(23*$s),(11*$s))))
            $dc.DrawGeometry($null, $pen, $geo)
        }
        else {
            $dc.DrawGeometry($null, $pen, [System.Windows.Media.Geometry]::Parse(
                (Format-Invariant 'M {0},{1} L {2},{3}' @((11*$s),(11*$s),(21*$s),(21*$s)))))
            $dc.DrawGeometry($null, $pen, [System.Windows.Media.Geometry]::Parse(
                (Format-Invariant 'M {0},{1} L {2},{3}' @((21*$s),(11*$s),(11*$s),(21*$s)))))
        }
    } 64
}

$script:IconTick  = New-ResultBadge '#FF107C10' 'tick'
$script:IconCross = New-ResultBadge '#FFC42B1C' 'cross'

try { $win.Icon = $script:IconApp } catch { }
$UI.ImgLogo.Source = $script:IconApp

# ---------------------------------------------------------------------- state --

$script:S = @{
    Child      = $null     # System.Diagnostics.Process of the running step
    ChildKind  = ''        # 'bootstrap' | 'install'
    Readers    = @()       # @{ PS = [powershell]; Handle = IAsyncResult } per stream
    Queue      = $null     # ConcurrentQueue[string] the readers feed
    Overall    = 0.0       # monotonic overall percent
    CompIndex  = 0         # current download component [i/N]
    CompTotal  = 0
    FailLines  = New-Object System.Collections.ArrayList
    AbortLine  = ''
    LastLine   = ''        # last non-empty line seen, for "it just died" reporting
    DryRun     = $false
    Cancelled  = $false
    Finished   = $false
    DetailsBuf = New-Object System.Text.StringBuilder
    WarnCount  = 0
}

# Overall progress budget. Downloads carry the weight: on a first online install
# they dominate wall-clock time (~2.7 GB), with quantisation of the default model
# second. Stage names are matched by prefix against Write-TiStep's '==> ' lines.
$script:DL_START  = 14.0
$script:DL_SPAN   = 56.0   # downloads own 14% -> 70%
$script:BOOT_SPAN = 8.0    # the pwsh bootstrap owns 0% -> 8% when it runs

$script:StageMap = @(
    @{ Prefix = 'Preflight checks';                          Head = 'Checking this computer';              Pct = 8.0  }
    @{ Prefix = 'Creating the install layout';               Head = 'Preparing folders';                   Pct = 12.0 }
    @{ Prefix = 'Downloading components';                    Head = 'Downloading speech models and tools'; Pct = 14.0 }
    @{ Prefix = 'Downloads skipped';                         Head = 'Downloads skipped';                   Pct = 68.0 }
    @{ Prefix = 'Deriving the default speech model';         Head = 'Preparing the speech model';          Pct = 70.0 }
    @{ Prefix = 'Model derivation skipped';                  Head = 'Preparing the speech model';          Pct = 81.0 }
    @{ Prefix = 'Installing app files';                      Head = 'Installing the app';                  Pct = 82.0 }
    @{ Prefix = 'Registering the Explorer right-click verb'; Head = 'Adding the right-click menu';         Pct = 86.0 }
    @{ Prefix = 'Shell registration skipped';                Head = 'Adding the right-click menu';         Pct = 86.0 }
    @{ Prefix = 'Creating the Send To entries';              Head = 'Adding the Send to menu';             Pct = 90.0 }
    @{ Prefix = 'Send To entries skipped';                   Head = 'Adding the Send to menu';             Pct = 90.0 }
    @{ Prefix = 'Writing install-manifest.json';             Head = 'Recording what was installed';        Pct = 93.0 }
    @{ Prefix = 'Post-install smoke test';                   Head = 'Checking everything works';           Pct = 95.0 }
    @{ Prefix = 'Dry run - planned actions';                 Head = 'Dry run: listing planned actions';    Pct = 60.0 }
)

# ------------------------------------------------------------------ UI updates --

function Set-Overall {
    # Monotonic: a download retry that resumes must never walk the bar backwards.
    param([double] $Pct)
    if ($Pct -lt $script:S.Overall) { $Pct = $script:S.Overall }
    if ($Pct -gt 100) { $Pct = 100 }
    $script:S.Overall = $Pct
    $UI.BarOverall.IsIndeterminate = $false
    $UI.BarOverall.Value = $Pct
    $UI.TbPct.Text = ('{0:N0}%' -f $Pct)
    try {
        $win.TaskbarItemInfo.ProgressState = [System.Windows.Shell.TaskbarItemProgressState]::Normal
        $win.TaskbarItemInfo.ProgressValue = $Pct / 100.0
    }
    catch { }
}

function Show-FileProgress {
    param([string] $Label, [double] $Pct)
    $UI.TbFile.Text = $Label
    $UI.TbFile.Visibility = 'Visible'
    $UI.BarFile.Visibility = 'Visible'
    if ($Pct -lt 0) { $UI.BarFile.IsIndeterminate = $true }
    else {
        $UI.BarFile.IsIndeterminate = $false
        if ($Pct -gt 100) { $Pct = 100 }
        $UI.BarFile.Value = $Pct
    }
}

function Hide-FileProgress {
    $UI.TbFile.Visibility = 'Collapsed'
    $UI.BarFile.Visibility = 'Collapsed'
    $UI.BarFile.IsIndeterminate = $false
}

function Update-FileProgress {
    # One '#TIDL|name|written|total' line from Invoke-TiDownload.
    param([string] $Name, [long] $Written, [long] $Total)
    if ($Total -gt 0) {
        $frac = $Written / [double]$Total
        if ($frac -gt 1) { $frac = 1 }
        Show-FileProgress -Label ('{0} - {1} of {2}' -f $Name, (Format-Bytes $Written), (Format-Bytes $Total)) -Pct (100.0 * $frac)
        if ($script:S.CompTotal -gt 0) {
            Set-Overall ($script:DL_START + $script:DL_SPAN * (($script:S.CompIndex - 1 + $frac) / $script:S.CompTotal))
        }
    }
    else {
        Show-FileProgress -Label ('{0} - {1} so far' -f $Name, (Format-Bytes $Written)) -Pct -1
    }
}

# ---------------------------------------------------------------- line parsing --

function Read-ChildLine {
    param([string] $Line)
    if ($null -eq $Line) { return }

    # Machine channel first. Not appended to the details pane: it IS the per-file
    # progress bar's data feed, and thousands of them would drown the useful text.
    if ($Line.StartsWith('#TIDL|')) {
        $parts = $Line.Split('|')
        if ($parts.Count -ge 4) {
            $w = [long]0; $t = [long]0
            [void][long]::TryParse($parts[2], [ref]$w)
            [void][long]::TryParse($parts[3], [ref]$t)
            Update-FileProgress -Name $parts[1] -Written $w -Total $t
        }
        return
    }

    [void]$script:S.DetailsBuf.AppendLine($Line)
    $trim = $Line.Trim()
    if ($trim.Length -gt 0) { $script:S.LastLine = $trim }

    # ---- the pwsh 7 bootstrap speaks Bootstrap-Pwsh.ps1's dialect ------------
    if ($script:S.ChildKind -eq 'bootstrap') {
        $m = [regex]::Match($Line, '\.\.\.\s+(\d+)\s+MB(?:\s+of\s+(\d+)\s+MB)?')
        if ($m.Success) {
            $done = [double]$m.Groups[1].Value
            if ($m.Groups[2].Success -and ([double]$m.Groups[2].Value) -gt 0) {
                $tot = [double]$m.Groups[2].Value
                Set-Overall (1.0 + ($script:BOOT_SPAN - 1.0) * ($done / $tot))
                Show-FileProgress -Label ('PowerShell 7 - {0} MB of {1} MB' -f [int]$done, [int]$tot) -Pct (100.0 * $done / $tot)
            }
            else {
                Show-FileProgress -Label ('PowerShell 7 - {0} MB so far' -f [int]$done) -Pct -1
            }
            return
        }
        if ($trim.Length -gt 0) { $UI.TbStatus.Text = $trim }
        return
    }

    # ---- '==> X': stage transition -------------------------------------------
    if ($Line.StartsWith('==> ')) {
        $stage = $Line.Substring(4).Trim()
        Hide-FileProgress
        $hit = $null
        foreach ($s in $script:StageMap) {
            if ($stage.StartsWith([string]$s.Prefix)) { $hit = $s; break }
        }
        if ($null -ne $hit) {
            $UI.TbStage.Text = [string]$hit.Head
            Set-Overall ([double]$hit.Pct)
        }
        else { $UI.TbStage.Text = $stage }
        $UI.TbStatus.Text = ''
        if ($stage.StartsWith('Dry run')) { $script:S.DryRun = $true }
        return
    }

    # ---- '    [i/N] name - size': component i of N ---------------------------
    $m = [regex]::Match($Line, '^\s+\[(\d+)/(\d+)\]\s+(.+)$')
    if ($m.Success) {
        $script:S.CompIndex = [int]$m.Groups[1].Value
        $script:S.CompTotal = [int]$m.Groups[2].Value
        $UI.TbStatus.Text = ('Component {0} of {1}: {2}' -f $script:S.CompIndex, $script:S.CompTotal, $m.Groups[3].Value.Trim())
        if ($script:S.CompTotal -gt 0) {
            Set-Overall ($script:DL_START + $script:DL_SPAN * (($script:S.CompIndex - 1) / $script:S.CompTotal))
        }
        Hide-FileProgress
        return
    }

    # ---- '    OK / WARN / FAIL ...': detail rows ------------------------------
    $m = [regex]::Match($Line, '^\s+(OK|WARN|FAIL)\s+(.+)$')
    if ($m.Success) {
        $kind = $m.Groups[1].Value
        $text = $m.Groups[2].Value.Trim()
        if ($kind -eq 'OK') {
            $UI.TbStatus.Text = $text
            Hide-FileProgress    # a finished/skipped download retires its bar
        }
        elseif ($kind -eq 'WARN') {
            $script:S.WarnCount++
            $UI.TbStatus.Text = 'Warning: ' + $text
        }
        else {
            [void]$script:S.FailLines.Add($text)
            $UI.TbStatus.Text = $text
        }
        return
    }

    # ---- terminal sentences ---------------------------------------------------
    if ($Line.StartsWith('Install aborted')) { $script:S.AbortLine = $trim; return }
    if ($trim.StartsWith('Dry run complete')) { $script:S.DryRun = $true; return }

    # ---- any other indented info line becomes the live status ----------------
    if ($trim.Length -gt 0 -and $Line.StartsWith('    ')) { $UI.TbStatus.Text = $trim }
}

# ------------------------------------------------------------- child processes --

function Start-Child {
    param(
        [string] $Exe,
        [string] $ArgString,
        [string] $Kind
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $ArgString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $script:SourceRoot
    if ($Kind -eq 'install') {
        # pwsh 7 writes UTF-8 when redirected; powershell.exe (bootstrap) writes
        # the console codepage but only ever emits ASCII, so it keeps the default.
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }

    $p = [System.Diagnostics.Process]::Start($psi)
    $script:S.Child = $p
    $script:S.ChildKind = $Kind

    # One dedicated blocking reader per stream, each on its own runspace, both
    # feeding one lock-free queue. Synchronous reads on the UI thread would
    # deadlock the child the moment a pipe buffer fills - same hazard Progress.ps1
    # and Invoke-Tool guard against with async reads.
    $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:S.Queue = $q
    $readers = @()
    foreach ($stream in @($p.StandardOutput, $p.StandardError)) {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
            param($sr, $queue)
            while ($true) {
                $line = $sr.ReadLine()
                if ($null -eq $line) { break }
                $queue.Enqueue($line)
            }
        }).AddArgument($stream).AddArgument($q)
        $readers += @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }
    $script:S.Readers = $readers
}

function Stop-ChildTree {
    # taskkill /T: the pwsh child spawns its own children (tar, whisper-quantize,
    # smoke-test exes); killing just the root would orphan a quantiser mid-write.
    $p = $script:S.Child
    if ($null -eq $p) { return }
    $exited = $false
    try { $exited = $p.HasExited } catch { $exited = $true }
    if ($exited) { return }
    try {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') `
                      -ArgumentList @('/PID', "$($p.Id)", '/T', '/F') `
                      -WindowStyle Hidden -Wait
    }
    catch { }
}

function Start-Bootstrap {
    $UI.TbStage.Text = 'Setting up PowerShell 7'
    $UI.TbStatus.Text = 'A one-time download of about 110 MB, for your account only'
    $UI.BarOverall.IsIndeterminate = $true
    try { $win.TaskbarItemInfo.ProgressState = [System.Windows.Shell.TaskbarItemProgressState]::Indeterminate } catch { }
    $boot = Join-Path $script:InstallerDir 'Bootstrap-Pwsh.ps1'
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Child -Exe $exe -Kind 'bootstrap' -ArgString (ConvertTo-ArgString @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $boot))
}

function Start-Installer {
    param([string] $Pwsh)
    $UI.TbStage.Text = 'Starting the installer'
    $UI.TbStatus.Text = ''
    $UI.BarOverall.IsIndeterminate = $true
    try { $win.TaskbarItemInfo.ProgressState = [System.Windows.Shell.TaskbarItemProgressState]::Indeterminate } catch { }
    $installer = Join-Path $script:InstallerDir 'Install-TranscribeIt.ps1'
    # Mirrors Install Heresay.cmd exactly: -SourceRoot is the folder holding app\
    # and installer\, and -DownloadCache only when the offline package ships one.
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer,
              '-SourceRoot', $script:SourceRoot)
    if ($script:HasOffline) { $argv += @('-DownloadCache', $script:DownloadCache) }
    foreach ($a in $script:PassArgs) { $argv += $a }
    Start-Child -Exe $Pwsh -Kind 'install' -ArgString (ConvertTo-ArgString $argv)
}

# --------------------------------------------------------------------- results --

$script:UsageText = @(
    'To transcribe a recording, find it in File Explorer, then either:'
    ''
    "    right-click it and choose 'Transcribe in PDF'"
    "    (you may need 'Show more options' first),  or"
    ''
    "    right-click it, then 'Send to' > 'Transcribe in PDF'."
    ''
    'The transcript PDF lands next to the recording when it finishes.'
) -join "`r`n"

function Get-FailureReason {
    param([int] $Code)
    $parts = New-Object System.Collections.ArrayList
    $fails = @($script:S.FailLines)
    if ($fails.Count -gt 0) {
        $take = [Math]::Min(3, $fails.Count)
        for ($i = 0; $i -lt $take; $i++) { [void]$parts.Add([string]$fails[$i]) }
        if ($fails.Count -gt $take) {
            [void]$parts.Add(('...and {0} more - the log has the full list.' -f ($fails.Count - $take)))
        }
    }
    if ($script:S.AbortLine) { [void]$parts.Add($script:S.AbortLine) }
    if ($parts.Count -eq 0) {
        if ($script:S.LastLine) {
            [void]$parts.Add(('The installer stopped unexpectedly (exit code {0}). Its last message was: "{1}"' -f $Code, $script:S.LastLine))
        }
        else {
            [void]$parts.Add(('The installer stopped unexpectedly (exit code {0}) without printing anything.' -f $Code))
        }
    }
    return ($parts.ToArray() -join "`r`n`r`n")
}

function Show-Result {
    # $Kind: 'done' | 'done-warn' | 'cancelled' | 'failed'
    param([string] $Kind, [string] $Reason = '')
    $script:S.Finished = $true
    Hide-FileProgress
    $UI.PaneWelcome.Visibility = 'Collapsed'
    $UI.PaneProgress.Visibility = 'Collapsed'
    $UI.PaneDone.Visibility = 'Visible'

    if ($Kind -eq 'done' -or $Kind -eq 'done-warn') {
        Set-Overall 100
        $UI.ImgResult.Source = $script:IconTick
        if ($script:S.DryRun) {
            $UI.TbResultTitle.Text = 'Dry run complete'
            $UI.TbResultBody.Text = 'Nothing was changed on this computer. Run the installer again without -WhatIf to install for real.'
        }
        elseif ($Kind -eq 'done-warn') {
            $UI.TbResultTitle.Text = 'Heresay is installed'
            $UI.TbResultBody.Text = $script:UsageText + "`r`n`r`n" +
                'Note: some post-install checks did not pass, so part of it may not work yet. The log has the detail.'
            $UI.BtnOpenLog.Visibility = 'Visible'
        }
        else {
            $UI.TbResultTitle.Text = 'Heresay is installed'
            $UI.TbResultBody.Text = $script:UsageText
        }
        try { $win.TaskbarItemInfo.ProgressState = [System.Windows.Shell.TaskbarItemProgressState]::None } catch { }
    }
    elseif ($Kind -eq 'cancelled') {
        $UI.ImgResult.Source = $script:IconCross
        $UI.TbResultTitle.Text = 'Install cancelled'
        $UI.TbResultBody.Text = 'The install was stopped because it was cancelled by you. ' +
            'Nothing more will be changed. Anything already downloaded is kept, so running the installer again later resumes rather than starting over.'
        $UI.BtnOpenLog.Visibility = 'Visible'
        try { $win.TaskbarItemInfo.ProgressState = [System.Windows.Shell.TaskbarItemProgressState]::Paused } catch { }
    }
    else {
        $UI.ImgResult.Source = $script:IconCross
        $UI.TbResultTitle.Text = 'The install did not finish'
        $UI.TbResultBody.Text = $Reason + "`r`n`r`n" +
            'Running the installer again is always safe - it resumes downloads and repairs in place. If it keeps failing, the log file has the full detail; please send it to whoever supports Heresay.'
        $UI.BtnOpenLog.Visibility = 'Visible'
        try {
            $win.TaskbarItemInfo.ProgressState = [System.Windows.Shell.TaskbarItemProgressState]::Error
            $win.TaskbarItemInfo.ProgressValue = 1.0
        }
        catch { }
    }
    [void]$UI.BtnClose.Focus()
}

function Open-LogFolder {
    # Install-TranscribeIt.ps1 logs to %TEMP%\TranscribeIt-install-*.log during
    # preflight and relocates to <InstallRoot>\logs\install.log via Move-TiLog
    # once the layout exists - so prefer that folder, fall back to %TEMP%.
    $logDir = Join-Path $script:InstallRoot 'logs'
    $target = $env:TEMP
    if (Test-Path -LiteralPath (Join-Path $logDir 'install.log')) { $target = $logDir }
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $target + '"') } catch { }
}

function Complete-Child {
    # Runs on the UI thread once the child exited, both readers finished, and the
    # line queue is fully drained.
    $p = $script:S.Child
    $kind = $script:S.ChildKind
    $code = 0
    try { $code = $p.ExitCode } catch { $code = -1 }
    foreach ($r in $script:S.Readers) { try { $r.PS.Dispose() } catch { } }
    $script:S.Readers = @()
    $script:S.Child = $null
    $script:S.ChildKind = ''
    $script:S.Queue = $null
    try { $p.Dispose() } catch { }

    if ($script:S.Cancelled) { Show-Result -Kind 'cancelled'; return }

    if ($kind -eq 'bootstrap') {
        if ($code -eq 0) {
            $pwsh = Find-Pwsh7
            if ($null -ne $pwsh) {
                Set-Overall $script:BOOT_SPAN
                Hide-FileProgress
                Start-Installer -Pwsh $pwsh
                return
            }
            Show-Result -Kind 'failed' -Reason 'PowerShell 7 reported a successful set-up but pwsh.exe could not be found afterwards. Ask IT to install PowerShell 7, then run this installer again.'
            return
        }
        $reason = 'PowerShell 7 - a Microsoft component Heresay needs - could not be set up.'
        if ($script:S.LastLine) { $reason = $reason + ' The last message was: "' + $script:S.LastLine + '"' }
        Show-Result -Kind 'failed' -Reason $reason
        return
    }

    # The installer itself. 0 = clean; 3 = installed but smoke tests failed;
    # 1/2/4 = aborted (preflight / download / deploy or derivation).
    if ($code -eq 0) { Show-Result -Kind 'done' }
    elseif ($code -eq 3) { Show-Result -Kind 'done-warn' }
    else { Show-Result -Kind 'failed' -Reason (Get-FailureReason -Code $code) }
}

# ----------------------------------------------------------------- pump timer --

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:Timer.add_Tick({
    try {
        $q = $script:S.Queue
        if ($null -ne $q) {
            $line = $null
            $n = 0
            while ($n -lt 500 -and $q.TryDequeue([ref]$line)) {
                Read-ChildLine -Line $line
                $n++
            }
        }
        if ($script:S.DetailsBuf.Length -gt 0) {
            $chunk = $script:S.DetailsBuf.ToString()
            [void]$script:S.DetailsBuf.Clear()
            $UI.TbDetails.AppendText($chunk)
            if ($UI.TbDetails.Visibility -eq [System.Windows.Visibility]::Visible) {
                $UI.TbDetails.ScrollToEnd()
            }
        }
        $p = $script:S.Child
        if ($null -ne $p -and $p.HasExited) {
            $allDone = $true
            foreach ($r in $script:S.Readers) {
                if (-not $r.Handle.IsCompleted) { $allDone = $false }
            }
            $empty = $true
            if ($null -ne $q) {
                $probe = $null
                if ($q.TryPeek([ref]$probe)) { $empty = $false }
            }
            if ($allDone -and $empty) { Complete-Child }
        }
    }
    catch { }
})
$script:Timer.Start()

# --------------------------------------------------------------------- wiring --

$UI.TbLoc.Text = $script:InstallRoot
if ($script:HasOffline) {
    $UI.TbDl.Text = 'No download needed - this package includes everything.'
}
else {
    $UI.TbDl.Text = 'The first install downloads about 2.7 GB of speech models and tools. It only happens once.'
}
$free = Get-FreeGB
if ($null -ne $free) {
    $UI.TbDisk.Text = ('{0} GB free on {1} (about 7 GB is needed during a first install)' -f $free, ([System.IO.Path]::GetPathRoot($script:InstallRoot)).TrimEnd('\'))
}
else {
    $UI.TbDisk.Text = 'Free space could not be read.'
}

$UI.BtnInstall.add_Click({
    $UI.PaneWelcome.Visibility = 'Collapsed'
    $UI.PaneProgress.Visibility = 'Visible'
    $pwsh = Find-Pwsh7
    if ($null -ne $pwsh) { Start-Installer -Pwsh $pwsh }
    else { Start-Bootstrap }
})

function Request-Cancel {
    # Returns $true if the user confirmed and the kill was issued.
    $p = $script:S.Child
    if ($null -eq $p) { return $false }
    $exited = $false
    try { $exited = $p.HasExited } catch { $exited = $true }
    if ($exited) { return $false }
    $r = [System.Windows.MessageBox]::Show($win,
        ("Stop installing Heresay?`r`n`r`n" +
         'Anything already downloaded is kept, so running the installer again later resumes rather than starting over.'),
        'Heresay Setup',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return $false }
    $script:S.Cancelled = $true
    $UI.TbStage.Text = 'Cancelling'
    $UI.TbStatus.Text = ''
    $UI.BtnProgressCancel.IsEnabled = $false
    Stop-ChildTree
    return $true
}

$UI.BtnProgressCancel.add_Click({ [void](Request-Cancel) })
$UI.BtnWelcomeCancel.add_Click({ $win.Close() })
$UI.BtnClose.add_Click({ $win.Close() })
$UI.BtnOpenLog.add_Click({ Open-LogFolder })

$UI.BtnDetails.add_Checked({
    $UI.BtnDetails.Content = 'Hide details'
    $UI.TbDetails.Visibility = 'Visible'
    $UI.TbDetails.ScrollToEnd()
})
$UI.BtnDetails.add_Unchecked({
    $UI.BtnDetails.Content = 'Show details'
    $UI.TbDetails.Visibility = 'Collapsed'
})

# Closing the window mid-install is a cancel request, not an escape hatch: keep
# the window open either way - to keep rendering if declined, to show the
# 'cancelled by you' pane if confirmed.
$win.add_Closing({
    param($s, $e)
    if ($script:S.Finished) { return }
    $p = $script:S.Child
    if ($null -eq $p) { return }
    $exited = $false
    try { $exited = $p.HasExited } catch { $exited = $true }
    if ($exited) { return }
    [void](Request-Cancel)
    $e.Cancel = $true
})

# ----------------------------------------------------------------------- show --

$null = $win.ShowDialog()
$script:Timer.Stop()
# Safety net: never leave an orphaned child installing into a half-shown UI.
if ($null -ne $script:S.Child) {
    $stillRunning = $false
    try { $stillRunning = -not $script:S.Child.HasExited } catch { }
    if ($stillRunning) { $script:S.Cancelled = $true; Stop-ChildTree }
}
exit 0

}
catch {
    # The console is hidden, so a startup failure would otherwise be silent.
    $msg = $_.Exception.Message
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [void][System.Windows.MessageBox]::Show(
            ("The Heresay setup window could not start:`r`n`r`n" + $msg +
             "`r`n`r`nYou can still install with the console version: double-click 'Install Heresay.cmd'."),
            'Heresay Setup')
    }
    catch { }
    exit 1
}
