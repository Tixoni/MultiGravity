#requires -version 5.1
# MultiGravity: лаунчер нескольких аккаунтов Antigravity поверх pgrav (ParaGravity).
# Статусы читаются напрямую (папки профилей + процессы), pgrav вызывается только для действий.
param([string]$Snapshot, [string]$SnapshotView)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, Microsoft.VisualBasic

$WindowTitle = 'MultiGravity'

# --- один экземпляр ---------------------------------------------------------
if (-not $Snapshot) {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\MultiGravity', [ref]$created)
    if (-not $created) {
        try { [Microsoft.VisualBasic.Interaction]::AppActivate($WindowTitle) } catch {}
        return
    }
}

# --- пути ---------------------------------------------------------------------
$script:ProfilesDir = $env:PARAGRAVITY_PROFILES_DIR
if (-not $script:ProfilesDir) { $script:ProfilesDir = $env:AGY_PROFILES_DIR }
if (-not $script:ProfilesDir) { $script:ProfilesDir = Join-Path $env:USERPROFILE '.antigravity-profiles' }
$script:ProfilesDir = [IO.Path]::GetFullPath($script:ProfilesDir)

$script:AgyExe = $env:ANTIGRAVITY_BIN
if (-not $script:AgyExe) { $script:AgyExe = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe' }

# pgrav: сначала версия из комплекта (vendor\paragravity), затем установленная отдельно
$script:Pgrav = Join-Path $PSScriptRoot 'vendor\paragravity\pgrav.cmd'
if (-not (Test-Path $script:Pgrav)) {
    $pgravCmd = Get-Command pgrav -ErrorAction SilentlyContinue
    if ($pgravCmd) { $script:Pgrav = $pgravCmd.Source } else { $script:Pgrav = Join-Path $env:USERPROFILE '.paragravity\bin\pgrav.cmd' }
}

$script:TempDir = Join-Path $env:TEMP 'multigravity'
New-Item -ItemType Directory -Force $script:TempDir | Out-Null

# кеш почты, тарифа и лимитов: лимиты отдаёт только запущенный аккаунт
$script:CacheFile = Join-Path $env:LOCALAPPDATA 'MultiGravity\cache.json'

# статистика считается stats.py по локальной истории разговоров
$script:StatsPy = Join-Path $PSScriptRoot 'stats.py'
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
$script:Python = if ($pythonCmd) { $pythonCmd.Source } else { 'python' }

# --- состояние ----------------------------------------------------------------
$script:Profiles    = @()
$script:Running     = @{}      # имя профиля -> pid
$script:MainPids    = @()
$script:Pending     = @{}      # id -> @{ State = 'starting'|'stopping'; Since = [datetime] }
$script:Info        = @{}      # id -> { Email; Name; Plan; Groups; At } из GetUserStatus
$script:LsByKey     = @{}      # id -> { Pid; Csrf } запущенного language server
$script:LsPorts     = @{}      # pid language server -> HTTP-порт
$script:QuotaPS     = $null
$script:QuotaAsync  = $null
$script:QuotaAt     = [datetime]::MinValue
$script:ModelLabels = @{}      # MODEL_* -> «Gemini 3.8 Flash (High)», из GetUserStatus
$script:StatsData   = @{}      # id -> результат stats.py
$script:StatsKey    = $null
$script:StatsPeriod = 'all'
$script:StatsLoading = $false
$script:StatsError  = ''
$script:Jobs        = New-Object System.Collections.ArrayList
$script:StatusPS    = $null
$script:StatusAsync = $null
$script:LastSig     = ''
$script:Tick        = 0
$script:ToastUntil  = $null
$script:MenuTarget  = $null
$script:DialogAction = $null

$Palette = @('#8AA4FF', '#F59E6B', '#5FD3A5', '#E57FD0', '#F2C94C', '#6FC3F7', '#B48CFF', '#FF8A8A')

# --- XAML ---------------------------------------------------------------------
$WindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="__TITLE__" Width="470" Height="620"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="#ECECEE"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Foreground" Value="#ECECEE"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8"/>
              <Border x:Name="Hv" Background="#FFFFFF" Opacity="0" CornerRadius="8"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hv" Property="Opacity" Value="0.07"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Hv" Property="Opacity" Value="0.13"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}"/>
    <Style x:Key="SoftBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#26262C"/>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#8AA4FF"/>
      <Setter Property="Foreground" Value="#0F1220"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#FF6B6B"/>
      <Setter Property="Foreground" Value="#1A0B0B"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Width" Value="32"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#9A9AA2"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#1B1B1F"/>
      <Setter Property="BorderBrush" Value="#25252B"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#202025"/>
          <Setter Property="BorderBrush" Value="#31313A"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Foreground" Value="#ECECEE"/>
      <Setter Property="CaretBrush" Value="#ECECEE"/>
      <Setter Property="SelectionBrush" Value="#8AA4FF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="#141417" BorderBrush="#2E2E35" BorderThickness="1" CornerRadius="8" Padding="8,7">
              <ScrollViewer x:Name="PART_ContentHost" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#8AA4FF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C9C9CF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="#212126" BorderBrush="#2E2E35" BorderThickness="1" CornerRadius="8" Padding="11,6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#28282E"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#222842"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#8AA4FF"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C9C9CF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Track" Width="34" Height="20" CornerRadius="10" Background="#2E2E35">
                <Ellipse x:Name="Knob" Width="14" Height="14" Fill="#A0A0A8" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#8AA4FF"/>
                <Setter TargetName="Knob" Property="Fill" Value="#0F1220"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MenuStyle" TargetType="ContextMenu">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Background="#1F1F24" BorderBrush="#34343C" BorderThickness="1" CornerRadius="10" Padding="4">
              <StackPanel IsItemsHost="True"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MenuItemStyle" TargetType="MenuItem">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Foreground" Value="#E8E8EB"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="10,7" MinWidth="176">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"
                           FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Width="24" VerticalAlignment="Center"/>
                <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#2C2C33"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#26262C"/>
      <Setter Property="Foreground" Value="#ECECEE"/>
      <Setter Property="BorderBrush" Value="#36363E"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border Background="#3A3A42" CornerRadius="3"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Border CornerRadius="16" Background="#141417">
      <Border.Effect><DropShadowEffect BlurRadius="22" ShadowDepth="0" Opacity="0.6" Color="#000000"/></Border.Effect>
    </Border>

    <Border x:Name="Root" CornerRadius="16" Background="#141417" BorderBrush="#26262C" BorderThickness="1" ClipToBounds="True">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Шапка -->
        <Grid x:Name="Header" Background="Transparent" Margin="18,16,10,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border Width="34" Height="34" CornerRadius="10" Background="#1E1E23" BorderBrush="#2A2A31" BorderThickness="1">
            <Image x:Name="Logo" Margin="6"/>
          </Border>
          <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="MultiGravity" FontSize="15" FontWeight="SemiBold"/>
            <TextBlock x:Name="Subtitle" Text="Аккаунты" FontSize="12" Foreground="#8E8E96" Margin="0,1,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Top">
            <Button x:Name="BtnMin" Style="{StaticResource IconBtn}" Content="&#xE921;" ToolTip="Свернуть"/>
            <Button x:Name="BtnClose" Style="{StaticResource IconBtn}" Content="&#xE8BB;" ToolTip="Закрыть"/>
          </StackPanel>
        </Grid>

        <!-- Список аккаунтов -->
        <ScrollViewer Grid.Row="1" Margin="14,4,8,0" Padding="0,0,6,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="List"/>
        </ScrollViewer>

        <!-- Низ -->
        <Border Grid.Row="2" BorderBrush="#202026" BorderThickness="0,1,0,0" Padding="14,10,10,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="BtnNew" Style="{StaticResource SoftBtn}" ToolTip="Ctrl+N">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE710;" FontFamily="{StaticResource Icons}" FontSize="11" VerticalAlignment="Center" Margin="0,1,8,0"/>
                <TextBlock Text="Новый аккаунт"/>
              </StackPanel>
            </Button>
            <StackPanel Grid.Column="2" Orientation="Horizontal">
              <Button x:Name="BtnStopAll" Style="{StaticResource IconBtn}" Content="&#xE7E8;" ToolTip="Закрыть все сессии"/>
              <Button x:Name="BtnDoctor" Style="{StaticResource IconBtn}" Content="&#xE90F;" ToolTip="Проверить и починить профили (pgrav doctor --fix)"/>
              <Button x:Name="BtnFolder" Style="{StaticResource IconBtn}" Content="&#xE8B7;" ToolTip="Папка профилей"/>
              <Button x:Name="BtnRefresh" Style="{StaticResource IconBtn}" Content="&#xE72C;" ToolTip="Обновить"/>
            </StackPanel>
          </Grid>
        </Border>

        <!-- Уведомление -->
        <Border x:Name="Toast" Grid.RowSpan="3" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="16,0,16,64"
                Background="#25252B" BorderBrush="#34343C" BorderThickness="1" CornerRadius="10" Padding="12,8" Visibility="Collapsed">
          <TextBlock x:Name="ToastText" TextWrapping="Wrap" MaxWidth="360" FontSize="12.5"/>
        </Border>

        <!-- Статистика аккаунта -->
        <Border x:Name="StatsOverlay" Grid.RowSpan="3" Background="#141417" CornerRadius="16" Visibility="Collapsed">
          <Grid Margin="16,14,8,12">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid x:Name="StatsHeader" Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="StatsBack" Style="{StaticResource IconBtn}" Content="&#xE72B;" ToolTip="Назад (Esc)" VerticalAlignment="Top"/>
              <StackPanel Grid.Column="1" Margin="8,2,0,0">
                <TextBlock x:Name="StatsTitle" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="StatsSub" FontSize="12" Foreground="#8E8E96" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <Button x:Name="StatsRefresh" Grid.Column="2" Style="{StaticResource IconBtn}" Content="&#xE72C;" ToolTip="Пересчитать" VerticalAlignment="Top" Margin="0,0,2,0"/>
            </Grid>
            <WrapPanel Grid.Row="1" Margin="2,12,0,4">
              <RadioButton x:Name="PeriodToday" GroupName="period" Style="{StaticResource Chip}" Content="Сегодня" Tag="today"/>
              <RadioButton x:Name="Period7" GroupName="period" Style="{StaticResource Chip}" Content="7 дней" Tag="7"/>
              <RadioButton x:Name="Period30" GroupName="period" Style="{StaticResource Chip}" Content="30 дней" Tag="30"/>
              <RadioButton x:Name="PeriodAll" GroupName="period" Style="{StaticResource Chip}" Content="Всё время" Tag="all" IsChecked="True"/>
            </WrapPanel>
            <ScrollViewer Grid.Row="2" Margin="0,4,0,0" Padding="2,0,8,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="StatsBody"/>
            </ScrollViewer>
          </Grid>
        </Border>

        <!-- Новый аккаунт -->
        <Border x:Name="CreateOverlay" Grid.RowSpan="3" Background="#CC0E0E10" CornerRadius="16" Visibility="Collapsed">
          <Border Background="#1B1B1F" BorderBrush="#2E2E35" BorderThickness="1" CornerRadius="14" Padding="18" Margin="20" VerticalAlignment="Center">
            <StackPanel>
              <TextBlock Text="Новый аккаунт" FontSize="16" FontWeight="SemiBold"/>
              <TextBlock Text="Отдельный профиль Antigravity со своим входом в Google." Foreground="#8E8E96" TextWrapping="Wrap" Margin="0,4,0,14"/>

              <TextBlock Text="Имя профиля" Foreground="#8E8E96" FontSize="12" Margin="0,0,0,5"/>
              <TextBox x:Name="NewName" Style="{StaticResource Input}"/>
              <TextBlock Text="латиница, цифры, точка, _ и -" FontSize="11" Foreground="#64646C" Margin="0,4,0,10"/>

              <TextBlock Text="Подпись, например почта аккаунта" Foreground="#8E8E96" FontSize="12" Margin="0,0,0,5"/>
              <TextBox x:Name="NewDesc" Style="{StaticResource Input}" Margin="0,0,0,12"/>

              <TextBlock Text="Настройки редактора" Foreground="#8E8E96" FontSize="12" Margin="0,0,0,6"/>
              <WrapPanel>
                <RadioButton x:Name="ModeClean" GroupName="mode" Style="{StaticResource Chip}" Content="Чистые" IsChecked="True"/>
                <RadioButton x:Name="ModeInherit" GroupName="mode" Style="{StaticResource Chip}" Content="Как в основном"/>
                <RadioButton x:Name="ModeClone" GroupName="mode" Style="{StaticResource Chip}" Content="Копия профиля"/>
              </WrapPanel>
              <WrapPanel x:Name="ClonePanel" Visibility="Collapsed" Margin="0,2,0,0"/>
              <TextBlock Text="Токены и вход никогда не копируются." FontSize="11" Foreground="#64646C" Margin="0,2,0,0"/>

              <CheckBox x:Name="NewLaunch" Style="{StaticResource Switch}" Content="Запустить сразу" IsChecked="True" Margin="0,14,0,0"/>

              <TextBlock x:Name="NewError" Foreground="#FF8A8A" TextWrapping="Wrap" Margin="0,12,0,0" Visibility="Collapsed"/>

              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                <Button x:Name="NewCancel" Style="{StaticResource GhostBtn}" Content="Отмена" Margin="0,0,8,0"/>
                <Button x:Name="NewOk" Style="{StaticResource PrimaryBtn}" Content="Создать"/>
              </StackPanel>
            </StackPanel>
          </Border>
        </Border>

        <!-- Диалог: подтверждение / ввод -->
        <Border x:Name="DialogOverlay" Grid.RowSpan="3" Background="#CC0E0E10" CornerRadius="16" Visibility="Collapsed">
          <Border Background="#1B1B1F" BorderBrush="#2E2E35" BorderThickness="1" CornerRadius="14" Padding="18" Margin="20" VerticalAlignment="Center">
            <StackPanel>
              <TextBlock x:Name="DialogTitle" FontSize="16" FontWeight="SemiBold"/>
              <TextBlock x:Name="DialogText" Foreground="#A6A6AE" TextWrapping="Wrap" Margin="0,6,0,0"/>
              <TextBox x:Name="DialogInput" Style="{StaticResource Input}" Margin="0,12,0,0" Visibility="Collapsed"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
                <Button x:Name="DialogCancel" Style="{StaticResource GhostBtn}" Content="Отмена" Margin="0,0,8,0"/>
                <Button x:Name="DialogOk" Style="{StaticResource PrimaryBtn}" Content="OK"/>
              </StackPanel>
            </StackPanel>
          </Border>
        </Border>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$CardXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Style="{DynamicResource Card}" Cursor="Hand">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid Width="40" Height="40" VerticalAlignment="Center">
      <Border x:Name="Avatar" CornerRadius="11" Background="__COLOR__">
        <TextBlock Text="__INITIAL__" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="16" FontWeight="SemiBold" Foreground="#101014"/>
      </Border>
      <Image x:Name="AvatarImg" Margin="8" Visibility="Collapsed"/>
      <Ellipse x:Name="Dot" Width="13" Height="13" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-3,-3"
               Stroke="#1B1B1F" StrokeThickness="2.5" Fill="#4A4A52"/>
    </Grid>
    <StackPanel Grid.Column="1" Margin="12,0,10,0" VerticalAlignment="Center">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="__TITLE__" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
        <Border x:Name="Plan" CornerRadius="5" Background="#252A40" Padding="6,1,6,2" Margin="8,1,0,0" VerticalAlignment="Center" Visibility="Collapsed">
          <TextBlock x:Name="PlanText" FontSize="10.5" FontWeight="SemiBold" Foreground="#AFC0FF"/>
        </Border>
      </StackPanel>
      <TextBlock x:Name="Sub" Text="__SUB__" FontSize="12" Foreground="#8E8E96" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"/>
    </StackPanel>
    <Button x:Name="Primary" Grid.Column="2" MinWidth="96" VerticalAlignment="Center"/>
    <Button x:Name="More" Grid.Column="3" Margin="4,0,-4,0" Content="&#xE712;" ToolTip="Ещё" VerticalAlignment="Center"/>
    <StackPanel x:Name="Quotas" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="3" Margin="12,6,0,0">__QUOTAS__</StackPanel>
  </Grid>
</Border>
'@

# Строка лимита внутри карточки: подпись, полоска, «96% · 1 ч 12 мин»
$QuotaRowXaml = @'
<Grid Margin="0,4,0,0" Opacity="__OP__" ToolTip="__TIP__" Background="Transparent">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="112"/>
    <ColumnDefinition Width="*"/>
    <ColumnDefinition Width="Auto"/>
  </Grid.ColumnDefinitions>
  <TextBlock Text="__LABEL__" FontSize="11.5" Foreground="#9A9AA2" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
  <Grid Grid.Column="1" Height="5" Margin="6,0,10,0" VerticalAlignment="Center">
    <Border CornerRadius="2.5" Background="#2A2A31"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="__A__*"/>
        <ColumnDefinition Width="__B__*"/>
      </Grid.ColumnDefinitions>
      <Border CornerRadius="2.5" Background="__COLOR__"/>
    </Grid>
  </Grid>
  <TextBlock Grid.Column="2" Text="__TEXT__" FontSize="11.5" Foreground="#C9C9CF" VerticalAlignment="Center" MinWidth="104"/>
</Grid>
'@

# --- вспомогательное ----------------------------------------------------------
function Esc([string]$s) { [Security.SecurityElement]::Escape([string]$s) }

function Get-Plural([int]$n, [string]$one, [string]$few, [string]$many) {
    $m10 = $n % 10; $m100 = $n % 100
    if ($m10 -eq 1 -and $m100 -ne 11) { return $one }
    if ($m10 -ge 2 -and $m10 -le 4 -and ($m100 -lt 12 -or $m100 -gt 14)) { return $few }
    return $many
}

function Get-ExeIcon([string]$path) {
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
        return [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $ico.Handle, [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    } catch { return $null }
}

function Get-ColorFor([string]$name) {
    $sum = 0
    foreach ($ch in $name.ToCharArray()) { $sum += [int]$ch }
    return $Palette[$sum % $Palette.Count]
}

function Read-TextUtf8([string]$path) { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }

# Почта из id_token профиля (декодируется только полезная нагрузка JWT, токены никуда не уходят)
function Get-TokenEmail([string]$tokenFile) {
    try {
        $tok = Read-TextUtf8 $tokenFile | ConvertFrom-Json
        $payload = ([string]$tok.id_token).Split('.')[1].Replace('-', '+').Replace('_', '/')
        while ($payload.Length % 4) { $payload += '=' }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        return [string]$claims.email
    } catch { return '' }
}

function Load-Cache {
    if (-not (Test-Path $script:CacheFile)) { return }
    try {
        $data = Read-TextUtf8 $script:CacheFile | ConvertFrom-Json
        foreach ($prop in $data.PSObject.Properties) {
            if ($prop.Name -eq '__models__') {
                foreach ($m in $prop.Value.PSObject.Properties) { $script:ModelLabels[$m.Name] = [string]$m.Value }
            } else {
                $script:Info[$prop.Name] = $prop.Value
            }
        }
    } catch {}
}

function Save-Cache {
    try {
        $keep = @('__main__') + @($script:Profiles | ForEach-Object { $_.Name })
        $out = [ordered]@{ '__models__' = $script:ModelLabels }
        foreach ($k in $script:Info.Keys) { if ($keep -contains $k) { $out[$k] = $script:Info[$k] } }
        New-Item -ItemType Directory -Force (Split-Path $script:CacheFile) | Out-Null
        [IO.File]::WriteAllText($script:CacheFile, ($out | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

function Format-Left([TimeSpan]$span) {
    if ($span.TotalMinutes -lt 1) { return 'меньше минуты' }
    if ($span.TotalHours -lt 1) { return "$([int][math]::Floor($span.TotalMinutes)) мин" }
    if ($span.TotalDays -lt 1) {
        $h = [int][math]::Floor($span.TotalHours)
        if ($span.Minutes) { return "$h ч $($span.Minutes) мин" } else { return "$h ч" }
    }
    return "$([int][math]::Floor($span.TotalDays)) д $($span.Hours) ч"
}

# Строки лимитов для карточки из сохранённой информации об аккаунте
function Get-QuotaRows($inf, [bool]$live) {
    $rows = @()
    if (-not $inf -or -not $inf.Groups) { return $rows }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $at = [datetime]::MinValue
    try { $at = [datetime]::Parse([string]$inf.At, $inv, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() } catch {}
    foreach ($g in @($inf.Groups)) {
        $frac = [double]$g.Fraction
        $reset = $null
        if ($g.Reset) { try { $reset = [datetime]::Parse([string]$g.Reset, $inv, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() } catch {} }
        $tip = if ($g.Families) { [string]$g.Families } else { [string]$g.Label }
        if ($reset -and $reset -le (Get-Date)) {
            # время сброса уже прошло: лимит восстановлен, точное значение будет при следующем запуске
            $frac = 1.0; $text = '100% · сброшен'; $tip += "`nЛимит уже сброшен"
        } else {
            $pct = [int][math]::Floor($frac * 100)
            $text = "$pct%"
            if ($reset) { $text += " · $(Format-Left ($reset - (Get-Date)))"; $tip += "`nСброс в $($reset.ToString('HH:mm, d MMM'))" }
        }
        if (-not $live -and $at -gt [datetime]::MinValue) { $tip += "`nДанные на $($at.ToString('HH:mm, d MMM')), аккаунт не запущен" }
        $color = if ($frac -ge 0.5) { '#5FD3A5' } elseif ($frac -ge 0.2) { '#F2C94C' } else { '#FF6B6B' }
        $rows += [pscustomobject]@{ Label = [string]$g.Label; Frac = $frac; Text = $text; Tip = $tip; Color = $color; Live = $live }
    }
    return $rows
}

function Show-Toast([string]$text, [switch]$IsError) {
    $ToastText.Text = $text
    if ($IsError) {
        $Toast.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#3A2026'))
        $Toast.BorderBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#5A2E36'))
        $script:ToastUntil = (Get-Date).AddSeconds(8)
    } else {
        $Toast.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#25252B'))
        $Toast.BorderBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#34343C'))
        $script:ToastUntil = (Get-Date).AddSeconds(4)
    }
    $Toast.Visibility = 'Visible'
    $anim = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [TimeSpan]::FromMilliseconds(160))
    $Toast.BeginAnimation([Windows.UIElement]::OpacityProperty, $anim)
}

# --- данные профилей -------------------------------------------------------------
function Load-Profiles {
    $list = @()
    if (Test-Path $script:ProfilesDir) {
        foreach ($d in (Get-ChildItem $script:ProfilesDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $metaFile = Join-Path $d.FullName 'profile.json'
            if (-not (Test-Path $metaFile)) { continue }
            $desc = ''
            try { $meta = Read-TextUtf8 $metaFile | ConvertFrom-Json; $desc = [string]$meta.description } catch {}
            $tokenFile = Join-Path $d.FullName 'home\.gemini\jetski-standalone-oauth-token'
            $hasToken = Test-Path $tokenFile
            $list += [pscustomobject]@{
                Name     = $d.Name
                Dir      = $d.FullName
                Desc     = $desc
                HasToken = $hasToken
                Email    = $(if ($hasToken) { Get-TokenEmail $tokenFile } else { '' })
                Needle   = (Join-Path $d.FullName 'data').ToLowerInvariant()
            }
        }
    }
    $script:Profiles = $list
}

# Верхние процессы Antigravity (без --type=) и их language server. Выполняется в фоне.
$StatusScript = {
    $all = @(Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe' OR Name='language_server.exe'" -Property ProcessId, ParentProcessId, Name, CommandLine)
    $tops = @($all | Where-Object { $_.Name -eq 'Antigravity.exe' -and $_.CommandLine -and $_.CommandLine -notmatch '--type=' } |
        ForEach-Object { [pscustomobject]@{ Id = [int]$_.ProcessId; Cmd = [string]$_.CommandLine } })
    $topIds = @($tops | ForEach-Object { $_.Id })
    $parents = @{}
    foreach ($p in $all) { $parents[[int]$p.ProcessId] = [int]$p.ParentProcessId }
    $ls = foreach ($p in ($all | Where-Object { $_.Name -eq 'language_server.exe' -and $_.CommandLine })) {
        $m = [regex]::Match($p.CommandLine, '--csrf_token[= ](\S+)')
        if (-not $m.Success) { continue }
        # поднимаемся по родителям до верхнего окна Antigravity, чтобы понять, чей это сервер
        $cur = [int]$p.ParentProcessId; $top = 0
        for ($i = 0; $i -lt 6 -and $cur; $i++) {
            if ($topIds -contains $cur) { $top = $cur; break }
            $cur = $parents[$cur]
        }
        if ($top) { [pscustomobject]@{ Pid = [int]$p.ProcessId; Top = $top; Csrf = $m.Groups[1].Value } }
    }
    [pscustomobject]@{ Tops = $tops; Ls = @($ls) }
}

# Почта, тариф и лимиты через локальный API language server (GetUserStatus). Выполняется в фоне.
$QuotaScript = {
    param($targets)
    $body = [Text.Encoding]::UTF8.GetBytes('{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}')
    function Get-Status([int]$port, [string]$csrf) {
        try {
            $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$port/exa.language_server_pb.LanguageServerService/GetUserStatus")
            $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Proxy = $null
            $req.Timeout = 5000; $req.ReadWriteTimeout = 5000
            $req.Headers.Add('X-Codeium-Csrf-Token', $csrf)
            $req.Headers.Add('Connect-Protocol-Version', '1')
            $req.ContentLength = $body.Length
            $st = $req.GetRequestStream(); $st.Write($body, 0, $body.Length); $st.Close()
            $resp = $req.GetResponse()
            $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            return $txt
        } catch { return $null }
    }
    foreach ($t in $targets) {
        $txt = $null; $used = 0
        if ($t.Port) { $txt = Get-Status $t.Port $t.Csrf; if ($txt) { $used = $t.Port } }
        if (-not $txt) {
            $ports = @(Get-NetTCPConnection -OwningProcess $t.Pid -State Listen -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty LocalPort | Sort-Object -Unique)
            foreach ($p in $ports) { $txt = Get-Status $p $t.Csrf; if ($txt) { $used = $p; break } }
        }
        if (-not $txt) { [pscustomobject]@{ Key = $t.Key; Pid = $t.Pid; Ok = $false }; continue }
        try { $us = ($txt | ConvertFrom-Json).userStatus } catch { [pscustomobject]@{ Key = $t.Key; Pid = $t.Pid; Ok = $false }; continue }

        # модели с общим пулом лимита (одинаковые остаток и время сброса) объединяем в одну строку
        $models = @(foreach ($c in @($us.cascadeModelConfigData.clientModelConfigs)) {
            $q = $c.quotaInfo
            if (-not $q -or -not $q.PSObject.Properties['resetTime']) { continue }
            $family = ([string]$c.label -replace '\s*\(.*$', '').Trim()
            $frac = 0.0
            if ($q.PSObject.Properties['remainingFraction']) { $frac = [double]$q.remainingFraction }   # 0 в ответе опускается
            [pscustomobject]@{ Family = $family; Brand = ($family -split ' ')[0]; Fraction = $frac; Reset = [string]$q.resetTime }
        })
        $groups = @(foreach ($g in @($models | Group-Object { '{0}|{1}' -f $_.Fraction, $_.Reset })) {
            $first = $g.Group[0]
            [pscustomobject]@{
                Label    = (@($g.Group | ForEach-Object { $_.Brand } | Sort-Object -Unique) -join ' · ')
                Families = (@($g.Group | ForEach-Object { $_.Family } | Sort-Object -Unique) -join ', ')
                Fraction = $first.Fraction
                Reset    = $first.Reset
            }
        })
        # если у двух групп одинаковая подпись (например, два пула Gemini), показываем названия моделей
        $dups = @($groups | Group-Object Label | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        foreach ($g in $groups) { if ($dups -contains $g.Label) { $g.Label = $g.Families } }

        $labels = @{}
        foreach ($c in @($us.cascadeModelConfigData.clientModelConfigs)) {
            if ($c.modelOrAlias.model -and $c.label) { $labels[[string]$c.modelOrAlias.model] = [string]$c.label }
        }

        [pscustomobject]@{
            Key = $t.Key; Pid = $t.Pid; Port = $used; Ok = $true; Models = $labels
            Info = [pscustomobject]@{
                Email  = [string]$us.email
                Name   = [string]$us.name
                Plan   = [string]$us.planStatus.planInfo.planName
                Groups = @($groups | Sort-Object Label | Select-Object Label, Families, Fraction, Reset)
                At     = (Get-Date).ToUniversalTime().ToString('o')
            }
        }
    }
}

function Start-QuotaQuery {
    if ($script:QuotaAsync) { return }
    $script:QuotaAt = Get-Date
    $targets = @(foreach ($k in @($script:LsByKey.Keys)) {
        $l = $script:LsByKey[$k]
        [pscustomobject]@{ Key = $k; Pid = $l.Pid; Csrf = $l.Csrf; Port = $script:LsPorts[[int]$l.Pid] }
    })
    if (-not $targets.Count) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($QuotaScript).AddArgument($targets)
    $script:QuotaPS = $ps
    $script:QuotaAsync = $ps.BeginInvoke()
}

function Apply-Quota($results) {
    $changed = $false
    foreach ($r in @($results)) {
        if (-not $r -or -not $r.Ok) { continue }
        $script:LsPorts[[int]$r.Pid] = [int]$r.Port
        $script:Info[[string]$r.Key] = $r.Info
        if ($r.Models) { foreach ($k in $r.Models.Keys) { $script:ModelLabels[$k] = $r.Models[$k] } }
        $changed = $true
    }
    if ($changed) { Save-Cache; Render }
}

# Нужно ли обновить лимиты: у запущенного аккаунта нет данных или они старше минуты
function Test-QuotaStale {
    foreach ($k in @($script:LsByKey.Keys)) {
        $inf = $script:Info[$k]
        if (-not $inf) { return $true }
        try {
            $at = [datetime]::Parse([string]$inf.At, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            if (((Get-Date).ToUniversalTime() - $at.ToUniversalTime()).TotalSeconds -gt 60) { return $true }
        } catch { return $true }
    }
    return $false
}

function Start-StatusQuery {
    if ($script:StatusAsync) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($StatusScript)
    $script:StatusPS = $ps
    $script:StatusAsync = $ps.BeginInvoke()
}

function Apply-Status($status) {
    Load-Profiles
    $status = @($status)[0]
    $profLower = $script:ProfilesDir.ToLowerInvariant()
    $running = @{}
    $main = @()
    $keyByTop = @{}
    foreach ($t in @($status.Tops)) {
        if (-not $t) { continue }
        $c = ([string]$t.Cmd).ToLowerInvariant()
        if ($c.Contains($profLower)) {
            foreach ($p in $script:Profiles) { if ($c.Contains($p.Needle)) { $running[$p.Name] = [int]$t.Id; $keyByTop[[int]$t.Id] = $p.Name } }
        } else {
            $main += [int]$t.Id
            $keyByTop[[int]$t.Id] = '__main__'
        }
    }
    $script:Running = $running
    $script:MainPids = $main

    $lsByKey = @{}
    foreach ($l in @($status.Ls)) {
        if (-not $l) { continue }
        $key = $keyByTop[[int]$l.Top]
        if ($key) { $lsByKey[$key] = $l }
    }
    $script:LsByKey = $lsByKey

    # снимаем «запускается / останавливается», когда состояние подтвердилось или прошло время
    foreach ($id in @($script:Pending.Keys)) {
        $pend = $script:Pending[$id]
        if ($id -eq '__main__') { $isUp = $main.Count -gt 0 } else { $isUp = $running.ContainsKey($id) }
        $age = ((Get-Date) - $pend.Since).TotalSeconds
        if ($pend.State -eq 'starting' -and ($isUp -or $age -gt 40)) { $script:Pending.Remove($id) }
        elseif ($pend.State -eq 'stopping' -and (-not $isUp -or $age -gt 30)) { $script:Pending.Remove($id) }
    }
    Render
}

function Get-State([string]$id) {
    if ($script:Pending.ContainsKey($id)) { return $script:Pending[$id].State }
    if ($id -eq '__main__') { if ($script:MainPids.Count -gt 0) { return 'running' } else { return 'stopped' } }
    if ($script:Running.ContainsKey($id)) { return 'running' }
    return 'stopped'
}

# --- отрисовка --------------------------------------------------------------------
function Render {
    $items = @()
    $mainInfo = $script:Info['__main__']
    $mainSub = 'Обычный запуск Antigravity'
    if ($mainInfo -and $mainInfo.Email) { $mainSub = [string]$mainInfo.Email }
    $items += [pscustomobject]@{
        Id = '__main__'; Title = 'Основной'; Sub = $mainSub; Warn = $false
        Color = '#24242A'; Initial = ''; State = (Get-State '__main__'); IsMain = $true
        Plan = $(if ($mainInfo) { [string]$mainInfo.Plan } else { '' })
        Quotas = @(Get-QuotaRows $mainInfo $script:LsByKey.ContainsKey('__main__'))
    }
    foreach ($p in $script:Profiles) {
        $inf = $script:Info[$p.Name]
        $email = $p.Email
        if (-not $email -and $inf) { $email = [string]$inf.Email }
        $parts = @()
        if ($p.Desc) { $parts += $p.Desc }
        if ($email -and $email -ne $p.Desc) { $parts += $email }
        $sub = $parts -join ' · '
        $warn = $false
        if (-not $p.HasToken) { $sub = if ($sub) { "$sub · нужно войти" } else { 'Нужно войти в Google-аккаунт' }; $warn = $true }
        elseif (-not $sub) { $sub = 'Вход выполнен' }
        $items += [pscustomobject]@{
            Id = $p.Name; Title = $p.Name; Sub = $sub; Warn = $warn
            Color = (Get-ColorFor $p.Name); Initial = $p.Name.Substring(0, 1).ToUpper()
            State = (Get-State $p.Name); IsMain = $false
            Plan = $(if ($inf -and $p.HasToken) { [string]$inf.Plan } else { '' })
            Quotas = $(if ($p.HasToken) { @(Get-QuotaRows $inf $script:LsByKey.ContainsKey($p.Name)) } else { @() })
        }
    }

    $sig = ($items | ForEach-Object {
        "$($_.Id)|$($_.Sub)|$($_.State)|$($_.Warn)|$($_.Plan)|" + (($_.Quotas | ForEach-Object { "$($_.Label)/$($_.Text)/$($_.Live)" }) -join ',')
    }) -join ';'
    if ($sig -eq $script:LastSig) { return }
    $script:LastSig = $sig

    $List.Children.Clear()
    foreach ($it in $items) { [void]$List.Children.Add((New-Card $it)) }

    $total = $items.Count
    $up = @($items | Where-Object { $_.State -eq 'running' }).Count
    $Subtitle.Text = "$total $(Get-Plural $total 'аккаунт' 'аккаунта' 'аккаунтов') · $up $(Get-Plural $up 'запущен' 'запущено' 'запущено')"
    $BtnStopAll.IsEnabled = $up -gt 0
}

function New-Card($it) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $quotaXaml = ''
    foreach ($q in @($it.Quotas | Where-Object { $_ })) {
        $a = [math]::Max([math]::Min($q.Frac, 1.0), 0.002)
        $quotaXaml += $QuotaRowXaml.Replace('__LABEL__', (Esc $q.Label)).Replace('__TEXT__', (Esc $q.Text)).Replace('__TIP__', ((Esc $q.Tip) -replace "`n", '&#10;')).
            Replace('__COLOR__', $q.Color).Replace('__OP__', $(if ($q.Live) { '1' } else { '0.55' })).
            Replace('__A__', $a.ToString('0.###', $inv)).Replace('__B__', (1.0 - $a + 0.0001).ToString('0.####', $inv))
    }
    $x = $CardXaml.Replace('__COLOR__', $it.Color).Replace('__INITIAL__', (Esc $it.Initial)).Replace('__TITLE__', (Esc $it.Title)).
        Replace('__SUB__', (Esc $it.Sub)).Replace('__QUOTAS__', $quotaXaml)
    $card = [Windows.Markup.XamlReader]::Parse($x)
    $card.Tag = $it.Id

    if ($it.Plan) { $card.FindName('PlanText').Text = $it.Plan; $card.FindName('Plan').Visibility = 'Visible' }
    if (-not $quotaXaml) { $card.FindName('Quotas').Visibility = 'Collapsed' }

    if ($it.IsMain -and $script:AppIcon) {
        $img = $card.FindName('AvatarImg'); $img.Source = $script:AppIcon; $img.Visibility = 'Visible'
    }
    if ($it.Warn) { $card.FindName('Sub').Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#E6B85C')) }

    $dot = $card.FindName('Dot')
    $dotColor = switch ($it.State) { 'running' { '#3DD68C' } 'starting' { '#F2C94C' } 'stopping' { '#F2C94C' } default { '#4A4A52' } }
    $dot.Fill = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($dotColor))

    $btn = $card.FindName('Primary')
    $btn.Tag = $it.Id
    switch ($it.State) {
        'running'  { $btn.Content = 'Открыть';     $btn.Style = $Window.FindResource('SoftBtn') }
        'starting' { $btn.Content = 'Запуск…';     $btn.Style = $Window.FindResource('SoftBtn'); $btn.IsEnabled = $false }
        'stopping' { $btn.Content = 'Остановка…';  $btn.Style = $Window.FindResource('SoftBtn'); $btn.IsEnabled = $false }
        default    { $btn.Content = 'Запустить';   $btn.Style = $Window.FindResource('PrimaryBtn') }
    }
    $btn.Add_Click({ param($s, $e) Invoke-Primary ([string]$s.Tag) })

    $more = $card.FindName('More')
    $more.Style = $Window.FindResource('IconBtn')
    $more.Tag = $it.Id
    $more.Add_Click({ param($s, $e) Show-ProfileMenu $s })

    $card.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.ClickCount -eq 2) { Invoke-Primary ([string]$s.Tag) }
    })
    return $card
}

# --- действия -----------------------------------------------------------------------
# Фоновая команда через cmd без окна; вывод собирается в файл и разбирается в Complete-Job
function Start-BgCommand([string]$Kind, [string]$Name, [string]$CommandLine, $Extra) {
    $out = Join-Path $script:TempDir ([guid]::NewGuid().ToString('N') + '.log')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /s /c "' + $CommandLine + ' > "' + $out + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch { Show-Toast "Не удалось выполнить команду: $($_.Exception.Message)" -IsError; return $false }
    [void]$script:Jobs.Add([pscustomobject]@{ Proc = $proc; Out = $out; Kind = $Kind; Name = $Name; Extra = $Extra })
    return $true
}

function Invoke-Pgrav([string]$Kind, [string]$Name, [string[]]$PgArgs, $Extra) {
    if (-not (Test-Path $script:Pgrav)) { Show-Toast 'pgrav не найден. Установите ParaGravity или проверьте PATH.' -IsError; return $false }
    $argStr = ($PgArgs | ForEach-Object {
        $a = ([string]$_) -replace '["%]', ''
        if ($a -match '\s' -or $a -eq '') { '"' + $a + '"' } else { $a }
    }) -join ' '
    return (Start-BgCommand $Kind $Name ('"' + $script:Pgrav + '" ' + $argStr) $Extra)
}

function Complete-Job($j) {
    $code = $j.Proc.ExitCode
    $text = ''
    try { $text = Read-TextUtf8 $j.Out } catch {}
    Remove-Item $j.Out -Force -ErrorAction SilentlyContinue
    $text = $text -replace "$([char]27)\[[0-9;]*m", ''
    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
    $last = if ($lines.Count) { $lines[-1].Trim() } else { '' }
    $errLine = ($lines | Where-Object { $_ -match 'Error' } | Select-Object -Last 1)
    if (-not $errLine) { $errLine = $last }

    switch ($j.Kind) {
        'launch' {
            if ($code -ne 0) { $script:Pending.Remove($j.Name); Show-Toast "Не удалось запустить «$($j.Name)»: $errLine" -IsError }
            Start-StatusQuery
        }
        'stop' {
            if ($code -ne 0) { $script:Pending.Remove($j.Name); Show-Toast "Не удалось остановить «$($j.Name)»: $errLine" -IsError }
            Start-StatusQuery
        }
        'create' {
            $NewOk.IsEnabled = $true; $NewOk.Content = 'Создать'
            if ($code -ne 0) {
                if ($j.Extra) { $script:Pending.Remove($j.Name) }
                $NewError.Text = if ($errLine) { $errLine } else { "pgrav завершился с кодом $code" }
                $NewError.Visibility = 'Visible'
            } else {
                $CreateOverlay.Visibility = 'Collapsed'
                if ($j.Extra) { Show-Toast "Профиль «$($j.Name)» создан. Войдите в Google в открывшемся окне." }
                else { Show-Toast "Профиль «$($j.Name)» создан." }
            }
            Start-StatusQuery
        }
        'delete' {
            if ($code -ne 0) { Show-Toast "Не удалось удалить «$($j.Name)»: $errLine" -IsError }
            else { Show-Toast "Профиль «$($j.Name)» удалён." }
            Start-StatusQuery
        }
        'doctor' {
            $BtnDoctor.IsEnabled = $true
            if ($code -ne 0) { Show-Toast "Проверка завершилась с ошибкой: $errLine" -IsError }
            else { Show-Toast "Проверка профилей: $last" }
            Start-StatusQuery
        }
        'stopmain' {
            if ($code -ne 0) { $script:Pending.Remove('__main__'); Show-Toast "Не удалось закрыть основной аккаунт: $last" -IsError }
            Start-StatusQuery
        }
        'stats' {
            if ($j.Name -eq $script:StatsKey) { $script:StatsLoading = $false }
            $start = $text.IndexOf('{')
            try {
                if ($code -ne 0 -or $start -lt 0) { throw ($(if ($last) { $last } else { "код $code" })) }
                $data = $text.Substring($start) | ConvertFrom-Json
                $data | Add-Member -NotePropertyName At -NotePropertyValue (Get-Date) -Force
                $script:StatsData[$j.Name] = $data
                $script:StatsError = ''
            } catch {
                $script:StatsError = "Не удалось посчитать статистику: $($_.Exception.Message)"
            }
            if ($j.Name -eq $script:StatsKey) { Render-Stats }
        }
    }
}

function Initialize-WinApi {
    if ('Agy.Win' -as [type]) { return }
    Add-Type -Namespace 'Agy' -Name 'Win' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
// Посылает WM_CLOSE всем видимым окнам процесса — как нажатие на крестик
public static int CloseWindows(int pid) {
    int n = 0;
    EnumWindows((h, l) => {
        uint p; GetWindowThreadProcessId(h, out p);
        if (p == (uint)pid && IsWindowVisible(h)) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); n++; }
        return true;
    }, IntPtr.Zero);
    return n;
}
'@
}

function Close-Pids([int[]]$pids) {
    Initialize-WinApi
    $n = 0
    foreach ($procId in $pids) { if ($procId) { $n += [Agy.Win]::CloseWindows($procId) } }
    return $n
}

function Focus-Pids([int[]]$pids) {
    Initialize-WinApi
    foreach ($procId in $pids) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
            $h = $proc.MainWindowHandle
            if ([Agy.Win]::IsIconic($h)) { [void][Agy.Win]::ShowWindowAsync($h, 9) }
            [void][Agy.Win]::SetForegroundWindow($h)
            return $true
        }
    }
    return $false
}

function Invoke-Primary([string]$id) {
    $state = Get-State $id
    if ($state -eq 'starting' -or $state -eq 'stopping') { return }

    if ($id -eq '__main__') {
        if ($state -eq 'running' -and (Focus-Pids $script:MainPids)) { return }
        if (-not (Test-Path $script:AgyExe)) { Show-Toast "Antigravity не найден: $($script:AgyExe)" -IsError; return }
        try { Start-Process -FilePath $script:AgyExe } catch { Show-Toast "Не удалось запустить Antigravity: $($_.Exception.Message)" -IsError; return }
        if ($state -ne 'running') { $script:Pending['__main__'] = @{ State = 'starting'; Since = Get-Date } }
        Render
        return
    }

    if ($state -eq 'running') {
        if (-not (Focus-Pids @($script:Running[$id]))) { Show-Toast "Окно «$id» не найдено. Возможно, оно свёрнуто в трей." }
        return
    }
    if (Invoke-Pgrav 'launch' $id @('launch', $id)) {
        $script:Pending[$id] = @{ State = 'starting'; Since = Get-Date }
        Render
    }
}

# Закрываем окна аккаунта, как крестиком: Antigravity сам завершит language server и успеет
# спросить про несохранённые файлы. `pgrav stop` (taskkill /T без /F) здесь не срабатывает —
# фоновые процессы Electron так не закрываются. Принудительно — только если окон нет вовсе.
function Invoke-Stop([string]$id) {
    if ($id -eq '__main__') { Stop-Main; return }
    $ok = $true
    if ((Close-Pids @($script:Running[$id])) -eq 0) { $ok = Invoke-Pgrav 'stop' $id @('stop', $id, '--force') }
    if ($ok) {
        $script:Pending[$id] = @{ State = 'stopping'; Since = Get-Date }
        Render
    }
}

function Stop-Main {
    $ok = $true
    if ((Close-Pids $script:MainPids) -eq 0) {
        foreach ($procId in @($script:MainPids)) {
            if (-not (Start-BgCommand 'stopmain' '__main__' "taskkill /PID $procId /T /F")) { $ok = $false }
        }
    }
    if ($ok) {
        $script:Pending['__main__'] = @{ State = 'stopping'; Since = Get-Date }
        Render
    }
}

function Stop-All {
    if ((Get-State '__main__') -eq 'running') { Stop-Main }
    foreach ($p in $script:Profiles) {
        if ((Get-State $p.Name) -eq 'running') { Invoke-Stop $p.Name }
    }
}

function Set-Description([string]$name, [string]$text) {
    $p = $script:Profiles | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $p) { return }
    $file = Join-Path $p.Dir 'profile.json'
    try {
        $meta = Read-TextUtf8 $file | ConvertFrom-Json
        if ($meta.PSObject.Properties['description']) { $meta.description = $text.Trim() }
        else { $meta | Add-Member -NotePropertyName description -NotePropertyValue $text.Trim() }
        $json = $meta | ConvertTo-Json -Depth 6
        # pgrav читает profile.json в системной кодировке, поэтому не-ASCII пишем как \uXXXX (так же делает json.dump)
        $sb = New-Object Text.StringBuilder
        foreach ($ch in $json.ToCharArray()) {
            if ([int]$ch -gt 127) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) } else { [void]$sb.Append($ch) }
        }
        [IO.File]::WriteAllText($file, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
        Start-StatusQuery
    } catch { Show-Toast "Не удалось сохранить подпись: $($_.Exception.Message)" -IsError }
}

# --- меню профиля ----------------------------------------------------------------------
function New-MenuItem([string]$header, [string]$glyph, [string]$action, [string]$color) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Style = $Window.FindResource('MenuItemStyle')
    $mi.Header = $header
    $mi.Tag = $glyph
    $mi.CommandParameter = $action
    if ($color) { $mi.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($color)) }
    $mi.Add_Click({ param($s, $e) Invoke-MenuAction ([string]$s.CommandParameter) })
    return $mi
}

function Show-ProfileMenu($button) {
    $id = [string]$button.Tag
    $script:MenuTarget = $id
    $state = Get-State $id
    $menu = New-Object Windows.Controls.ContextMenu
    $menu.Style = $Window.FindResource('MenuStyle')
    [void]$menu.Items.Add((New-MenuItem 'Статистика' ([string][char]0xE9D2) 'stats'))
    if ($state -eq 'running') { [void]$menu.Items.Add((New-MenuItem 'Закрыть' ([string][char]0xE71A) 'stop')) }
    if ($id -eq '__main__') {
        [void]$menu.Items.Add((New-MenuItem 'Логи' ([string][char]0xE9F9) 'logs'))
        [void]$menu.Items.Add((New-MenuItem 'Папка данных' ([string][char]0xE8B7) 'folder'))
    } else {
        [void]$menu.Items.Add((New-MenuItem 'Подпись…' ([string][char]0xE70F) 'desc'))
        [void]$menu.Items.Add((New-MenuItem 'Логи' ([string][char]0xE9F9) 'logs'))
        [void]$menu.Items.Add((New-MenuItem 'Папка профиля' ([string][char]0xE8B7) 'folder'))
        [void]$menu.Items.Add((New-MenuItem 'Удалить…' ([string][char]0xE74D) 'delete' '#FF8A8A'))
    }
    $menu.PlacementTarget = $button
    $menu.Placement = 'Bottom'
    $menu.HorizontalOffset = -150
    $menu.IsOpen = $true
}

function Invoke-MenuAction([string]$action) {
    $id = $script:MenuTarget
    if ($action -eq 'stats') { Show-Stats $id; return }
    if ($id -eq '__main__') {
        switch ($action) {
            'stop'   { Stop-Main }
            'logs'   { Start-Process explorer.exe -ArgumentList "`"$(Join-Path $env:APPDATA 'Antigravity\logs')`"" }
            'folder' { Start-Process explorer.exe -ArgumentList "`"$(Join-Path $env:USERPROFILE '.gemini\antigravity')`"" }
        }
        return
    }
    $p = $script:Profiles | Where-Object { $_.Name -eq $id } | Select-Object -First 1
    if (-not $p) { return }
    switch ($action) {
        'stop'   { Invoke-Stop $id }
        'desc'   { Show-Dialog -Title 'Подпись профиля' -Text "Как подписать «$id» в списке, например почта аккаунта." -OkText 'Сохранить' -InputValue $p.Desc -Action @{ Kind = 'desc'; Name = $id } }
        'logs'   {
            $logs = Join-Path $p.Dir 'data\logs'
            if (-not (Test-Path $logs)) { $logs = Join-Path $p.Dir 'logs' }
            Start-Process explorer.exe -ArgumentList "`"$logs`""
        }
        'folder' { Start-Process explorer.exe -ArgumentList "`"$($p.Dir)`"" }
        'delete' {
            if ((Get-State $id) -ne 'stopped') { Show-Toast "Сначала остановите «$id»." -IsError; return }
            Show-Dialog -Title "Удалить «$id»?" -Text 'Будут удалены все данные профиля: вход в Google, история чатов и настройки. Это нельзя отменить.' -OkText 'Удалить' -Danger -Action @{ Kind = 'delete'; Name = $id }
        }
    }
}

# --- статистика -------------------------------------------------------------------------
$FragmentNs = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'

function Add-StatsXaml([string]$inner) {
    [void]$StatsBody.Children.Add([Windows.Markup.XamlReader]::Parse("<StackPanel $FragmentNs>$inner</StackPanel>"))
}

function Format-Num([double]$v) {
    if ($v -ge 1e9) { return ('{0:0.#} млрд' -f ($v / 1e9)) }
    if ($v -ge 1e6) { return ('{0:0.#} млн' -f ($v / 1e6)) }
    if ($v -ge 1e4) { return ('{0:0} тыс.' -f ($v / 1e3)) }
    if ($v -ge 1e3) { return ('{0:0.#} тыс.' -f ($v / 1e3)) }
    return ('{0:0}' -f $v)
}

function Format-Minutes([double]$min) {
    if ($min -lt 1) { return 'меньше минуты' }
    $m = [int][math]::Round($min)
    if ($m -lt 60) { return "$m мин" }
    $h = [int][math]::Floor($m / 60); $r = $m % 60
    if ($r) { return "$h ч $r мин" } else { return "$h ч" }
}

function Format-Secs([double]$s) {
    if ($s -lt 60) { return ('{0:0.#} с' -f $s) }
    return (Format-Minutes ($s / 60))
}

function Get-ModelLabel([string]$enum, [string]$name) {
    if ($script:ModelLabels.ContainsKey($enum)) { return $script:ModelLabels[$enum] }
    if ($name) { return $name }
    return $enum
}

function Get-AgyDir([string]$id) {
    if ($id -eq '__main__') { return (Join-Path $env:USERPROFILE '.gemini\antigravity') }
    $p = $script:Profiles | Where-Object { $_.Name -eq $id } | Select-Object -First 1
    if ($p) { return (Join-Path $p.Dir 'home\.gemini\antigravity') }
    return $null
}

function Start-Stats([string]$id) {
    $dir = Get-AgyDir $id
    $script:StatsError = ''
    if (-not $dir -or -not (Test-Path $dir)) {
        $script:StatsData[$id] = [pscustomobject]@{ conversations = 0; rows = @(); activity = @(); convs = @(); At = Get-Date }
    } elseif (-not (Test-Path $script:StatsPy)) {
        $script:StatsError = 'Рядом с загрузчиком нет stats.py.'
    } else {
        $script:StatsLoading = (Start-BgCommand 'stats' $id ('"' + $script:Python + '" -I "' + $script:StatsPy + '" "' + $dir + '"'))
    }
    Render-Stats
}

function Show-Stats([string]$id) {
    $script:StatsKey = $id
    $inf = $script:Info[$id]
    $email = if ($inf) { [string]$inf.Email } else { '' }
    if ($id -eq '__main__') { $title = 'Основной' }
    else {
        $title = $id
        $p = $script:Profiles | Where-Object { $_.Name -eq $id } | Select-Object -First 1
        if ($p -and $p.Email) { $email = $p.Email }
    }
    $StatsTitle.Text = "Статистика · $title"
    $StatsSub.Text = if ($email) { $email } else { 'Локальная история разговоров' }
    $StatsOverlay.Visibility = 'Visible'
    $cached = $script:StatsData[$id]
    if (-not $cached -or ((Get-Date) - $cached.At).TotalSeconds -gt 30) { Start-Stats $id } else { Render-Stats }
}

function Get-TileXaml([string]$label, [string]$value, [string]$sub) {
    @"
<Border Background="#1B1B1F" BorderBrush="#25252B" BorderThickness="1" CornerRadius="10" Padding="12,10" Margin="0,0,8,8">
  <StackPanel>
    <TextBlock Text="$(Esc $label)" FontSize="11.5" Foreground="#8E8E96"/>
    <TextBlock Text="$(Esc $value)" FontSize="20" FontWeight="SemiBold" Margin="0,2,0,0"/>
    <TextBlock Text="$(Esc $sub)" FontSize="11" Foreground="#6E6E76" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
</Border>
"@
}

function Get-SectionXaml([string]$text) {
    "<TextBlock Text=`"$(Esc $text)`" FontSize=`"12`" Foreground=`"#8E8E96`" Margin=`"2,10,0,6`"/>"
}

function Render-Stats {
    $StatsBody.Children.Clear()
    $data = $script:StatsData[$script:StatsKey]
    if (-not $data -or $script:StatsError) {
        $msg = if ($script:StatsError) { $script:StatsError } elseif ($script:StatsLoading) { 'Считаем статистику…' } else { 'Нет данных.' }
        Add-StatsXaml "<TextBlock Text=`"$(Esc $msg)`" Foreground=`"#8E8E96`" Margin=`"2,16,0,0`" TextWrapping=`"Wrap`"/>"
        return
    }

    $inv = [Globalization.CultureInfo]::InvariantCulture
    $today = (Get-Date).Date
    $from = switch ($script:StatsPeriod) { 'today' { $today } '7' { $today.AddDays(-6) } '30' { $today.AddDays(-29) } default { $null } }
    $fromStr = if ($from) { $from.ToString('yyyy-MM-dd') } else { '' }

    $rows = @($data.rows | Where-Object { $_ -and $_.d -ge $fromStr })
    $acts = @($data.activity | Where-Object { $_ -and $_.d -ge $fromStr })
    $convCount = @($data.convs | Where-Object { @($_ | Where-Object { $_ -ge $fromStr }).Count -gt 0 }).Count

    # агрегаты по моделям и по дням
    $models = @{}
    $byDay = @{}
    $tot = @{ N = 0.0; In = 0.0; Out = 0.0; Think = 0.0; Cache = 0.0; Gen = 0.0 }
    foreach ($r in $rows) {
        if (-not $models.ContainsKey($r.m)) {
            $models[$r.m] = [pscustomobject]@{ M = [string]$r.m; Name = [string]$r.name; N = 0.0; In = 0.0; Out = 0.0; Think = 0.0; Cache = 0.0; Gen = 0.0; Ttft = 0.0; Cr = 0.0 }
        }
        $a = $models[$r.m]
        $a.N += $r.n; $a.In += $r.'in'; $a.Out += $r.out; $a.Think += $r.think; $a.Cache += $r.cache
        $a.Gen += $r.gen; $a.Ttft += $r.ttft; $a.Cr += $r.cr
        if (-not $a.Name -and $r.name) { $a.Name = [string]$r.name }
        $tot.N += $r.n; $tot.In += $r.'in'; $tot.Out += $r.out; $tot.Think += $r.think; $tot.Cache += $r.cache; $tot.Gen += $r.gen
        if (-not $byDay.ContainsKey($r.d)) { $byDay[$r.d] = @{ N = 0.0; Tok = 0.0 } }
        $byDay[$r.d].N += $r.n
        $byDay[$r.d].Tok += $r.'in' + $r.cache + $r.out
    }
    $actMin = [double](($acts | Measure-Object -Property min -Sum).Sum)
    $actDays = @($acts | Where-Object { $_.steps -gt 0 }).Count
    $tokens = $tot.In + $tot.Cache + $tot.Out

    # плитки с итогами
    $tiles = (Get-TileXaml 'Запросы' (Format-Num $tot.N) "$($models.Count) $(Get-Plural $models.Count 'модель' 'модели' 'моделей')") +
             (Get-TileXaml 'Токены' (Format-Num $tokens) "выход $(Format-Num $tot.Out) · кеш $(Format-Num $tot.Cache)") +
             (Get-TileXaml 'Активность' (Format-Minutes $actMin) "$actDays $(Get-Plural $actDays 'день' 'дня' 'дней') с работой") +
             (Get-TileXaml 'Разговоры' ([string]$convCount) "генерация $(Format-Secs $tot.Gen)")
    Add-StatsXaml "<UniformGrid Columns=`"2`" Margin=`"0,4,-8,0`">$tiles</UniformGrid>"

    # активность по дням
    if ($script:StatsPeriod -ne 'today') {
        $actByDay = @{}
        foreach ($a in @($data.activity)) { if ($a) { $actByDay[[string]$a.d] = $a } }
        $days = switch ($script:StatsPeriod) {
            '7' { 7 } '30' { 30 }
            default {
                $firstAct = @($data.activity | Where-Object { $_ })
                $first = if ($firstAct.Count) { [datetime]::ParseExact([string]$firstAct[0].d, 'yyyy-MM-dd', $inv) } else { $today }
                [int][math]::Min([math]::Max(($today - $first).TotalDays + 1, 7), 60)
            }
        }
        $maxMin = 0.0
        for ($i = $days - 1; $i -ge 0; $i--) {
            $k = $today.AddDays(-$i).ToString('yyyy-MM-dd')
            if ($actByDay[$k] -and [double]$actByDay[$k].min -gt $maxMin) { $maxMin = [double]$actByDay[$k].min }
        }
        $cells = ''
        for ($i = $days - 1; $i -ge 0; $i--) {
            $day = $today.AddDays(-$i); $k = $day.ToString('yyyy-MM-dd')
            $min = if ($actByDay[$k]) { [double]$actByDay[$k].min } else { 0.0 }
            $req = if ($byDay[$k]) { $byDay[$k].N } else { 0 }
            $tok = if ($byDay[$k]) { $byDay[$k].Tok } else { 0 }
            $busy = $min -gt 0 -or $req -gt 0
            $h = if ($busy -and $maxMin -gt 0) { [math]::Max(4, 56 * $min / $maxMin) } elseif ($busy) { 4 } else { 2 }
            $color = if ($busy) { '#8AA4FF' } else { '#2A2A31' }
            $tip = "$($day.ToString('d MMMM, dddd'))&#10;Активность: $(Format-Minutes $min)&#10;Запросы: $req · токены: $(Format-Num $tok)"
            if (-not $busy) { $tip = "$($day.ToString('d MMMM, dddd'))&#10;Без работы" }
            $cells += "<Border Background=`"Transparent`" ToolTip=`"$tip`"><Border VerticalAlignment=`"Bottom`" Height=`"$($h.ToString('0.#', $inv))`" CornerRadius=`"2`" Background=`"$color`" Margin=`"1.5,0`"/></Border>"
        }
        $firstLabel = $today.AddDays(-($days - 1)).ToString('d MMM')
        Add-StatsXaml ((Get-SectionXaml 'Активность по дням') + @"
<Border Background="#1B1B1F" BorderBrush="#25252B" BorderThickness="1" CornerRadius="10" Padding="10,10,10,8">
  <StackPanel>
    <UniformGrid Rows="1" Columns="$days" Height="58">$cells</UniformGrid>
    <Grid Margin="2,6,2,0">
      <TextBlock Text="$(Esc $firstLabel)" FontSize="11" Foreground="#6E6E76"/>
      <TextBlock Text="сегодня" FontSize="11" Foreground="#6E6E76" HorizontalAlignment="Right"/>
    </Grid>
  </StackPanel>
</Border>
"@)
    }

    # по моделям
    $list = @($models.Values | Sort-Object { $_.In + $_.Cache + $_.Out } -Descending)
    if (-not $list.Count) {
        Add-StatsXaml "<TextBlock Text=`"За этот период запросов к моделям не было.`" Foreground=`"#8E8E96`" Margin=`"2,14,0,0`"/>"
    } else {
        $maxTok = ($list | ForEach-Object { $_.In + $_.Cache + $_.Out } | Measure-Object -Maximum).Maximum
        $cards = Get-SectionXaml 'По моделям'
        foreach ($m in $list) {
            $tok = $m.In + $m.Cache + $m.Out
            $frac = if ($maxTok) { [math]::Max($tok / $maxTok, 0.002) } else { 0.002 }
            $line1 = "$(Format-Num $m.N) $(Get-Plural ([int]$m.N) 'запрос' 'запроса' 'запросов') · вход $(Format-Num $m.In) · из кеша $(Format-Num $m.Cache) · выход $(Format-Num $m.Out)"
            $parts = @()
            if ($m.Think) { $parts += "размышления $(Format-Num $m.Think)" }
            if ($m.N) { $parts += "первый токен ~$(Format-Secs ($m.Ttft / $m.N))" }
            $parts += "генерация $(Format-Secs $m.Gen)"
            if ($m.Cr) { $parts += "кредиты $(Format-Num $m.Cr)" }
            $cards += @"
<Border Background="#1B1B1F" BorderBrush="#25252B" BorderThickness="1" CornerRadius="10" Padding="12,10" Margin="0,0,0,8">
  <StackPanel>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Text="$(Esc (Get-ModelLabel $m.M $m.Name))" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
      <TextBlock Grid.Column="1" Text="$(Esc "$(Format-Num $tok) токенов")" Foreground="#C9C9CF" Margin="8,0,0,0"/>
    </Grid>
    <Grid Height="5" Margin="0,8,0,8">
      <Border CornerRadius="2.5" Background="#2A2A31"/>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="$($frac.ToString('0.###', $inv))*"/>
          <ColumnDefinition Width="$((1.0 - $frac + 0.0001).ToString('0.####', $inv))*"/>
        </Grid.ColumnDefinitions>
        <Border CornerRadius="2.5" Background="#8AA4FF"/>
      </Grid>
    </Grid>
    <TextBlock Text="$(Esc $line1)" FontSize="11.5" Foreground="#9A9AA2" TextWrapping="Wrap"/>
    <TextBlock Text="$(Esc ($parts -join ' · '))" FontSize="11.5" Foreground="#9A9AA2" TextWrapping="Wrap" Margin="0,2,0,0"/>
  </StackPanel>
</Border>
"@
        }
        Add-StatsXaml $cards
    }

    $at = if ($data.At) { ([datetime]$data.At).ToString('HH:mm') } else { '' }
    Add-StatsXaml "<TextBlock Text=`"$(Esc "По истории разговоров на этом компьютере: удалённые разговоры и другие устройства не учитываются. Посчитано в $at.")`" FontSize=`"11`" Foreground=`"#64646C`" TextWrapping=`"Wrap`" Margin=`"2,6,0,6`"/>"
}

# --- диалоги ----------------------------------------------------------------------------
function Show-Dialog([string]$Title, [string]$Text, [string]$OkText, [switch]$Danger, $InputValue, $Action) {
    $DialogTitle.Text = $Title
    $DialogText.Text = $Text
    $DialogOk.Content = $OkText
    if ($Danger) { $DialogOk.Style = $Window.FindResource('DangerBtn') } else { $DialogOk.Style = $Window.FindResource('PrimaryBtn') }
    if ($null -ne $InputValue) {
        $DialogInput.Text = [string]$InputValue
        $DialogInput.Visibility = 'Visible'
    } else {
        $DialogInput.Visibility = 'Collapsed'
    }
    $script:DialogAction = $Action
    $DialogOverlay.Visibility = 'Visible'
    if ($DialogInput.Visibility -eq 'Visible') { [void]$DialogInput.Focus(); $DialogInput.SelectAll() } else { [void]$DialogCancel.Focus() }
}

function Confirm-Dialog {
    $a = $script:DialogAction
    $DialogOverlay.Visibility = 'Collapsed'
    if (-not $a) { return }
    switch ($a.Kind) {
        'delete' { [void](Invoke-Pgrav 'delete' $a.Name @('delete', $a.Name, '-f')) }
        'desc'   { Set-Description $a.Name $DialogInput.Text }
        'closeall' { Stop-All }
    }
    $script:DialogAction = $null
}

function Show-Create {
    $NewName.Text = ''
    $NewDesc.Text = ''
    $NewError.Visibility = 'Collapsed'
    $ModeClean.IsChecked = $true
    $NewLaunch.IsChecked = $true
    $NewOk.IsEnabled = $true; $NewOk.Content = 'Создать'
    $ClonePanel.Children.Clear()
    $first = $true
    foreach ($p in $script:Profiles) {
        $rb = New-Object Windows.Controls.RadioButton
        $rb.Style = $Window.FindResource('Chip')
        $rb.GroupName = 'clone'
        $rb.Content = $p.Name
        $rb.Tag = $p.Name
        if ($first) { $rb.IsChecked = $true; $first = $false }
        [void]$ClonePanel.Children.Add($rb)
    }
    $ModeClone.IsEnabled = $script:Profiles.Count -gt 0
    $ClonePanel.Visibility = 'Collapsed'
    $CreateOverlay.Visibility = 'Visible'
    [void]$NewName.Focus()
}

function Submit-Create {
    $name = $NewName.Text.Trim()
    $desc = ($NewDesc.Text.Trim()) -replace '["%]', ''
    $err = $null
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { $err = 'Имя: только латиница, цифры, точка, _ и -, начинается с буквы или цифры.' }
    elseif (Test-Path (Join-Path $script:ProfilesDir $name)) { $err = "Профиль «$name» уже есть." }
    if ($err) { $NewError.Text = $err; $NewError.Visibility = 'Visible'; return }

    $pgArgs = @('create', $name, '--links', 'minimal')
    if ($desc) { $pgArgs += @('-d', $desc) }
    if ($ModeInherit.IsChecked) { $pgArgs += '-i' }
    elseif ($ModeClone.IsChecked) {
        $src = $ClonePanel.Children | Where-Object { $_.IsChecked } | Select-Object -First 1
        if ($src) { $pgArgs += @('--clone-from', [string]$src.Tag) }
    }
    $launch = [bool]$NewLaunch.IsChecked
    if ($launch) { $pgArgs += '--launch' }

    $NewError.Visibility = 'Collapsed'
    $NewOk.IsEnabled = $false; $NewOk.Content = 'Создаём…'
    if (Invoke-Pgrav 'create' $name $pgArgs $launch) {
        if ($launch) { $script:Pending[$name] = @{ State = 'starting'; Since = Get-Date } }
    } else {
        $NewOk.IsEnabled = $true; $NewOk.Content = 'Создать'
    }
}

# --- окно -------------------------------------------------------------------------------
$Window = [Windows.Markup.XamlReader]::Parse($WindowXaml.Replace('__TITLE__', $WindowTitle))
foreach ($n in 'Header', 'Logo', 'Subtitle', 'BtnMin', 'BtnClose', 'List', 'BtnNew', 'BtnDoctor', 'BtnFolder', 'BtnRefresh',
               'Toast', 'ToastText', 'CreateOverlay', 'NewName', 'NewDesc', 'ModeClean', 'ModeInherit', 'ModeClone',
               'ClonePanel', 'NewLaunch', 'NewError', 'NewCancel', 'NewOk',
               'DialogOverlay', 'DialogTitle', 'DialogText', 'DialogInput', 'DialogCancel', 'DialogOk',
               'BtnStopAll', 'StatsOverlay', 'StatsHeader', 'StatsBack', 'StatsTitle', 'StatsSub', 'StatsRefresh', 'StatsBody',
               'PeriodToday', 'Period7', 'Period30', 'PeriodAll') {
    Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script
}

$script:AppIcon = Get-ExeIcon $script:AgyExe   # значок основного аккаунта в списке
# своя иконка для окна (её собирает install.ps1); без неё — значок Antigravity
$ownIcon = Join-Path $PSScriptRoot 'multigravity.ico'
$winIcon = if (Test-Path $ownIcon) { [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$ownIcon) } else { $script:AppIcon }
if ($winIcon) { $Logo.Source = $winIcon; $Window.Icon = $winIcon }

$Header.Add_MouseLeftButtonDown({ try { $Window.DragMove() } catch {} })
$BtnMin.Add_Click({ $Window.WindowState = 'Minimized' })
$BtnClose.Add_Click({ $Window.Close() })
$BtnNew.Add_Click({ Show-Create })
$BtnRefresh.Add_Click({ $script:LastSig = ''; Start-StatusQuery; Start-QuotaQuery })
$BtnFolder.Add_Click({ if (Test-Path $script:ProfilesDir) { Start-Process explorer.exe -ArgumentList "`"$($script:ProfilesDir)`"" } })
$BtnDoctor.Add_Click({
    if (Invoke-Pgrav 'doctor' '' @('doctor', '--fix')) { $BtnDoctor.IsEnabled = $false; Show-Toast 'Проверяем профили…' }
})
$BtnStopAll.Add_Click({
    $names = @()
    if ((Get-State '__main__') -eq 'running') { $names += 'Основной' }
    $names += @($script:Profiles | Where-Object { (Get-State $_.Name) -eq 'running' } | ForEach-Object { $_.Name })
    if (-not $names.Count) { return }
    Show-Dialog -Title 'Закрыть все сессии?' -Text "Будут закрыты окна Antigravity: $($names -join ', '). Если есть несохранённые файлы, Antigravity спросит, сохранить ли их." -OkText 'Закрыть все' -Danger -Action @{ Kind = 'closeall' }
})

$StatsBack.Add_Click({ $StatsOverlay.Visibility = 'Collapsed' })
$StatsRefresh.Add_Click({ if ($script:StatsKey) { Start-Stats $script:StatsKey } })
$StatsHeader.Add_MouseLeftButtonDown({ try { $Window.DragMove() } catch {} })
foreach ($chip in $PeriodToday, $Period7, $Period30, $PeriodAll) {
    $chip.Add_Checked({ param($s, $e) $script:StatsPeriod = [string]$s.Tag; if ($StatsOverlay.Visibility -eq 'Visible') { Render-Stats } })
}

$ModeClone.Add_Checked({ $ClonePanel.Visibility = 'Visible' })
$ModeClone.Add_Unchecked({ $ClonePanel.Visibility = 'Collapsed' })
$NewCancel.Add_Click({ $CreateOverlay.Visibility = 'Collapsed' })
$NewOk.Add_Click({ Submit-Create })
$DialogCancel.Add_Click({ $DialogOverlay.Visibility = 'Collapsed'; $script:DialogAction = $null })
$DialogOk.Add_Click({ Confirm-Dialog })

$Window.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') {
        if ($DialogOverlay.Visibility -eq 'Visible') { $DialogOverlay.Visibility = 'Collapsed'; $e.Handled = $true }
        elseif ($CreateOverlay.Visibility -eq 'Visible') { $CreateOverlay.Visibility = 'Collapsed'; $e.Handled = $true }
        elseif ($StatsOverlay.Visibility -eq 'Visible') { $StatsOverlay.Visibility = 'Collapsed'; $e.Handled = $true }
    } elseif ($e.Key -eq 'Return') {
        if ($DialogOverlay.Visibility -eq 'Visible') { Confirm-Dialog; $e.Handled = $true }
        elseif ($CreateOverlay.Visibility -eq 'Visible' -and $NewOk.IsEnabled) { Submit-Create; $e.Handled = $true }
    } elseif ($e.Key -eq 'N' -and [Windows.Input.Keyboard]::Modifiers -eq 'Control') {
        if ($DialogOverlay.Visibility -ne 'Visible') { Show-Create; $e.Handled = $true }
    }
})

$Window.Add_Activated({
    Start-StatusQuery
    if (((Get-Date) - $script:QuotaAt).TotalSeconds -gt 20) { Start-QuotaQuery }
})

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(300)
$Timer.Add_Tick({
    for ($i = $script:Jobs.Count - 1; $i -ge 0; $i--) {
        $j = $script:Jobs[$i]
        if ($j.Proc.HasExited) { $script:Jobs.RemoveAt($i); Complete-Job $j }
    }
    if ($script:StatusAsync -and $script:StatusAsync.IsCompleted) {
        $res = @()
        try { $res = $script:StatusPS.EndInvoke($script:StatusAsync) } catch {}
        $script:StatusPS.Dispose()
        $script:StatusPS = $null; $script:StatusAsync = $null
        Apply-Status $res
    }
    if ($script:QuotaAsync -and $script:QuotaAsync.IsCompleted) {
        $res = @()
        try { $res = $script:QuotaPS.EndInvoke($script:QuotaAsync) } catch {}
        $script:QuotaPS.Dispose()
        $script:QuotaPS = $null; $script:QuotaAsync = $null
        Apply-Quota $res
    }
    $script:Tick++
    $every = if ($script:Pending.Count -gt 0) { 4 } else { 15 }
    if ($script:Tick % $every -eq 0) { Start-StatusQuery }
    # лимиты: раз в минуту для запущенных аккаунтов; пока сервер только стартует, повторяем каждые 8 с
    if ($script:Tick % 10 -eq 0 -and ((Get-Date) - $script:QuotaAt).TotalSeconds -gt 8 -and (Test-QuotaStale)) { Start-QuotaQuery }
    # раз в минуту перерисовываем «осталось N мин»
    if ($script:Tick % 200 -eq 0) { Render }
    if ($script:ToastUntil -and (Get-Date) -gt $script:ToastUntil) { $Toast.Visibility = 'Collapsed'; $script:ToastUntil = $null }
})

$Window.Add_Closed({
    $Timer.Stop()
    Get-ChildItem $script:TempDir -Filter *.log -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch {} }
})

# первый статус синхронно, чтобы окно открылось уже с актуальными точками
Load-Cache
Apply-Status (& $StatusScript)

if ($Snapshot) {
    # режим проверки: отрисовать окно в PNG и выйти
    Start-QuotaQuery
    if ($script:QuotaAsync) {
        while (-not $script:QuotaAsync.IsCompleted) { Start-Sleep -Milliseconds 100 }
        Apply-Quota ($script:QuotaPS.EndInvoke($script:QuotaAsync))
        $script:QuotaPS.Dispose(); $script:QuotaPS = $null; $script:QuotaAsync = $null
    }
    switch ($SnapshotView) {
        'create' { Show-Create; $ModeClone.IsChecked = $true; $NewName.Text = 'work'; $NewError.Text = 'Пример ошибки'; $NewError.Visibility = 'Visible' }
        'delete' { $script:MenuTarget = 'second'; Invoke-MenuAction 'delete' }
        'toast'  { Show-Toast 'Профиль «work» создан. Войдите в Google в открывшемся окне.' }
        'closeall' { $script:MainPids = @(1); Render; $BtnStopAll.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        { $_ -like 'stats*' } {
            # stats, stats-7, stats-second, ...
            $parts = $_ -split '-'
            $key = if ($parts.Count -gt 2) { $parts[2] } else { '__main__' }
            $raw = (& $script:Python -I $script:StatsPy (Get-AgyDir $key)) -join ''
            $d = $raw | ConvertFrom-Json; $d | Add-Member -NotePropertyName At -NotePropertyValue (Get-Date)
            $script:StatsData[$key] = $d
            if ($parts.Count -gt 1 -and $parts[1]) { $script:StatsPeriod = $parts[1]; ($PeriodToday, $Period7, $Period30, $PeriodAll | Where-Object { $_.Tag -eq $parts[1] }).IsChecked = $true }
            Show-Stats $key
            $Window.Height = 1100   # в снимке видно всё содержимое без прокрутки
        }
    }
    $Window.Add_ContentRendered({
        $Window.Dispatcher.BeginInvoke([Action]{
            $w = [int]$Window.ActualWidth; $h = [int]$Window.ActualHeight
            $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($Window.Content)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
            $Window.Close()
        }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    })
} else {
    Start-QuotaQuery
}

$Timer.Start()
[void]$Window.ShowDialog()
