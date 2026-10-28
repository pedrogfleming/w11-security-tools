# ==========================================
# SCRIPT: Radar-Tray.ps1
# Icono en la bandeja del sistema + dashboard de corridas.
#
# Muestra todas las corridas (logs\radar-*.log), permite abrir el informe
# de cada una y controlar si las tareas del radar se ejecutan o no.
#
# Uso:
#   .\Radar-Tray.ps1                 # solo el icono en el tray
#   .\Radar-Tray.ps1 -Mostrar        # arranca y abre el dashboard
#   .\Radar-Tray.ps1 -SinIcono       # sin tray, solo el dashboard (para pruebas)
#
# Acciones de administracion (pausar/reactivar/correr) se lanzan con UAC.
# El icono corre SIN privilegios: solo lee archivos y muestra ventanas.
# ==========================================

param(
    [switch]$Mostrar,
    [switch]$SinIcono,
    [ValidateSet('', 'Disable', 'Enable', 'Run')]
    [string]$AccionTarea = ''
)

$ErrorActionPreference = 'Stop'

$script:dirScript   = $PSScriptRoot
$script:dirLogs     = Join-Path $PSScriptRoot 'logs'
$script:configPath  = Join-Path $PSScriptRoot 'Radar.config.psd1'
$script:PatronTarea = 'Seguridad - *'
$script:TareaDash   = 'Seguridad - Dashboard Radar'
$script:MutexNombre = 'Local\RadarSeguridadTray'

# Programa con el que se abren los informes (misma clave que el radar)
$script:Config = @{ AbrirDetalleCon = 'notepad.exe' }
if (Test-Path -LiteralPath $script:configPath) {
    try {
        $cfg = Import-PowerShellDataFile -Path $script:configPath
        if ($cfg -and $cfg.ContainsKey('AbrirDetalleCon')) {
            $script:Config.AbrirDetalleCon = [string]$cfg.AbrirDetalleCon
        }
    } catch {
        Write-Verbose "Radar.config.psd1 ilegible: $($_.Exception.Message)"
    }
}

$script:Icono = $null
$script:UiForm = $null
$script:UiGrid = $null
$script:UiEstado = $null
$script:UiBotonAlternar = $null
$script:UiItemAlternar = $null
$script:RefrescarDashboard = $null
$script:TimerDashboard = $null
$script:UltimoVisto = ''

# ---------------------------------------------------------
# Datos
# ---------------------------------------------------------
function Get-TareasRadar {
    @(Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object {
            $_.TaskName -like $script:PatronTarea -and $_.TaskName -ne $script:TareaDash
        } |
        Sort-Object TaskName |
        ForEach-Object {
            [pscustomobject]@{
                Nombre = $_.TaskName
                Estado = "$($_.State)"
                Activa = ("$($_.State)" -ne 'Disabled')
            }
        })
}

function Read-InformesRadar {
    param(
        [string]$Directorio = $script:dirLogs,
        [int]$Maximo = 200
    )

    $salida = @()
    if ([string]::IsNullOrWhiteSpace($Directorio) -or -not (Test-Path -LiteralPath $Directorio)) {
        return $salida
    }

    $archivos = @(Get-ChildItem -Path $Directorio -Filter 'radar-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $Maximo)

    foreach ($f in $archivos) {
        $info = [pscustomobject]@{
            Fecha        = $f.LastWriteTime
            Criticos     = 0
            Avisos       = 0
            Informativos = 0
            Equipo       = ''
            Elevado      = ''
            Evento       = ''
            Archivo      = $f.FullName
        }

        try {
            $lineas = @(Get-Content -LiteralPath $f.FullName -TotalCount 25 -Encoding UTF8 -ErrorAction Stop)
            foreach ($l in $lineas) {
                if ($l -match '^Fecha\s*:\s*(.+)$') {
                    try {
                        $info.Fecha = [datetime]::ParseExact($Matches[1].Trim(), 'dd/MM/yyyy HH:mm:ss', $null)
                    } catch {
                        Write-Verbose "Fecha con formato inesperado en $($f.Name)"
                    }
                } elseif ($l -match '^Equipo\s*:\s*(.+)$') {
                    $info.Equipo = $Matches[1].Trim()
                } elseif ($l -match '^Elevado\s*:\s*(.+)$') {
                    $info.Elevado = $Matches[1].Trim()
                } elseif ($l -match '^Evento\s*:\s*(.+)$') {
                    $info.Evento = $Matches[1].Trim()
                } elseif ($l -match '^Resultado\s*:\s*(\d+)\s+criticos,\s*(\d+)\s+avisos,\s*(\d+)\s+informativos') {
                    $info.Criticos = [int]$Matches[1]
                    $info.Avisos = [int]$Matches[2]
                    $info.Informativos = [int]$Matches[3]
                }
            }
        } catch {
            Write-Verbose "No se pudo leer $($f.FullName): $($_.Exception.Message)"
        }

        $salida += $info
    }

    return $salida
}

function Open-Informe {
    param([string]$Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta) -or -not (Test-Path -LiteralPath $Ruta)) {
        Write-Warning "El informe no existe: $Ruta"
        return
    }

    $exe = [string]$script:Config.AbrirDetalleCon
    try {
        if ([string]::IsNullOrWhiteSpace($exe)) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Ruta`""
        } else {
            Start-Process -FilePath $exe -ArgumentList "`"$Ruta`""
        }
    } catch {
        try {
            Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$Ruta`""
        } catch {
            Write-Warning "No se pudo abrir el informe: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------
# Acciones sobre las tareas (requieren Administrador)
# ---------------------------------------------------------
function Invoke-AccionTareaElevada {
    param([ValidateSet('Disable', 'Enable', 'Run')][string]$Accion)

    $argumentos = @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"", '-AccionTarea', $Accion
    )
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru `
            -WindowStyle Hidden -ArgumentList $argumentos -ErrorAction Stop
        return ($p.ExitCode -eq 0)
    } catch {
        Write-Verbose "Accion cancelada o fallida: $($_.Exception.Message)"
        return $false
    }
}

function Update-GridRadar {
    param($Grid)

    if (-not $Grid) { return }
    $Grid.Rows.Clear()

    foreach ($i in (Read-InformesRadar -Maximo 200)) {
        $idx = $Grid.Rows.Add(
            $i.Fecha.ToString('dd/MM/yyyy HH:mm'),
            $i.Criticos,
            $i.Avisos,
            $i.Elevado,
            (Split-Path $i.Archivo -Leaf),
            $i.Evento
        )
        $Grid.Rows[$idx].Tag = $i.Archivo

        if ($i.Criticos -gt 0) {
            $Grid.Rows[$idx].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(253, 231, 233)
        } elseif ($i.Avisos -gt 0) {
            $Grid.Rows[$idx].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 220)
        }
    }
}

function Get-ResumenEstadoRadar {
    $tareas = @(Get-TareasRadar)
    $activas = @($tareas | Where-Object { $_.Activa })
    $ultimos = @(Read-InformesRadar -Maximo 1)

    $estado = 'SIN TAREAS'
    if ($tareas.Count -gt 0) {
        if ($activas.Count -eq $tareas.Count) { $estado = 'ACTIVO' }
        elseif ($activas.Count -eq 0) { $estado = 'PAUSADO' }
        else { $estado = 'PARCIAL' }
    }

    $linea1 = "Radar: $estado     Tareas: $($activas.Count) de $($tareas.Count) activas"
    if ($tareas.Count -gt 0) {
        $linea1 += '     ' + (($tareas | ForEach-Object { "$($_.Nombre): $($_.Estado)" }) -join ' | ')
    }

    $linea2 = 'Ultima corrida: (sin informes)'
    if ($ultimos.Count -gt 0) {
        $u = $ultimos[0]
        $linea2 = "Ultima corrida: $($u.Fecha.ToString('dd/MM/yyyy HH:mm')) -> $($u.Criticos) criticos, $($u.Avisos) avisos"
    }

    if ($tareas.Count -gt 0) {
        try {
            $info = Get-ScheduledTaskInfo -TaskName $tareas[0].Nombre -ErrorAction Stop
            if ($info.NextRunTime) {
                $linea2 += "     Proxima: $($info.NextRunTime.ToString('dd/MM/yyyy HH:mm'))"
            }
            $linea2 += "     Ultimo resultado: 0x$('{0:X}' -f $info.LastTaskResult)"
        } catch {
            Write-Verbose "Sin informacion de la proxima corrida: $($_.Exception.Message)"
        }
    }

    return "$linea1`r`n$linea2"
}

function Update-EstadoRadar {
    $tareas = @(Get-TareasRadar)
    $pendientes = @($tareas | Where-Object { -not $_.Activa })
    $todasActivas = ($tareas.Count -gt 0) -and ($pendientes.Count -eq 0)

    if ($script:UiEstado) { $script:UiEstado.Text = Get-ResumenEstadoRadar }

    if ($script:UiBotonAlternar) {
        if ($todasActivas) { $script:UiBotonAlternar.Text = 'Pausar radar' }
        else { $script:UiBotonAlternar.Text = 'Reactivar radar' }
    }

    if ($script:UiItemAlternar) {
        if ($todasActivas) { $script:UiItemAlternar.Text = 'Pausar radar' }
        else { $script:UiItemAlternar.Text = 'Reactivar radar' }
    }
}

# ---------------------------------------------------------
# Dashboard
# ---------------------------------------------------------
function New-Dashboard {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $ancho = 1000
    $alto = 620
    $yBotones = 66
    $yGrid = 106
    $altoGrid = 466
    $yPie = 578

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Radar de Seguridad - Dashboard'
    $form.ClientSize = New-Object System.Drawing.Size($ancho, $alto)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 460)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.Icon = [System.Drawing.SystemIcons]::Shield

    $lblEstado = New-Object System.Windows.Forms.Label
    $lblEstado.Location = New-Object System.Drawing.Point(16, 12)
    $lblEstado.Size = New-Object System.Drawing.Size(968, 44)
    $lblEstado.Anchor = 'Top, Left, Right'
    $lblEstado.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lblEstado.Text = 'Cargando...'
    $form.Controls.Add($lblEstado)

    $btnCorrer = New-Object System.Windows.Forms.Button
    $btnCorrer.Text = 'Correr ahora'
    $btnCorrer.Location = New-Object System.Drawing.Point(16, $yBotones)
    $btnCorrer.Size = New-Object System.Drawing.Size(130, 30)
    $form.Controls.Add($btnCorrer)

    $btnAlternar = New-Object System.Windows.Forms.Button
    $btnAlternar.Text = 'Pausar radar'
    $btnAlternar.Location = New-Object System.Drawing.Point(156, $yBotones)
    $btnAlternar.Size = New-Object System.Drawing.Size(140, 30)
    $form.Controls.Add($btnAlternar)

    $btnCarpeta = New-Object System.Windows.Forms.Button
    $btnCarpeta.Text = 'Abrir carpeta'
    $btnCarpeta.Location = New-Object System.Drawing.Point(306, $yBotones)
    $btnCarpeta.Size = New-Object System.Drawing.Size(130, 30)
    $form.Controls.Add($btnCarpeta)

    $btnRefrescar = New-Object System.Windows.Forms.Button
    $btnRefrescar.Text = 'Actualizar'
    $btnRefrescar.Location = New-Object System.Drawing.Point(446, $yBotones)
    $btnRefrescar.Size = New-Object System.Drawing.Size(110, 30)
    $form.Controls.Add($btnRefrescar)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(16, $yGrid)
    $grid.Size = New-Object System.Drawing.Size(968, $altoGrid)
    $grid.Anchor = 'Top, Bottom, Left, Right'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = 'FixedSingle'
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    foreach ($c in @(
            @{ T = 'Fecha';    R = 24 },
            @{ T = 'Criticos'; R = 10 },
            @{ T = 'Avisos';   R = 10 },
            @{ T = 'Elevado';  R = 10 },
            @{ T = 'Archivo';  R = 32 },
            @{ T = 'Evento';   R = 45 }
        )) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $c.T
        $col.FillWeight = $c.R
        $col.SortMode = 'NotSortable'
        [void]$grid.Columns.Add($col)
    }
    $form.Controls.Add($grid)

    $lblPie = New-Object System.Windows.Forms.Label
    $lblPie.Text = 'Doble click en una fila para abrir el informe. Se actualiza solo cada 20 segundos.'
    $lblPie.Location = New-Object System.Drawing.Point(16, $yPie)
    $lblPie.AutoSize = $true
    $lblPie.ForeColor = [System.Drawing.Color]::DimGray
    $lblPie.Anchor = 'Bottom, Left'
    $form.Controls.Add($lblPie)

    # Referencias a nivel script: los handlers las resuelven siempre.
    $script:UiForm = $form
    $script:UiGrid = $grid
    $script:UiEstado = $lblEstado
    $script:UiBotonAlternar = $btnAlternar

    $refrescar = {
        Update-EstadoRadar
        Update-GridRadar -Grid $script:UiGrid
    }
    $script:RefrescarDashboard = $refrescar

    $btnRefrescar.Add_Click($refrescar)

    $btnCarpeta.Add_Click({
        if (Test-Path -LiteralPath $script:dirLogs) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:dirLogs)`""
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Todavia no hay informes en $($script:dirLogs).",
                'Radar', 'OK', 'Information')
        }
    })

    $btnCorrer.Add_Click({
        if (Invoke-AccionTareaElevada -Accion 'Run') {
            Start-Sleep -Milliseconds 800
            & $script:RefrescarDashboard
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                'No se pudo iniciar la corrida (UAC cancelado o error).',
                'Radar', 'OK', 'Warning')
        }
    })

    $btnAlternar.Add_Click({
        $tareas = @(Get-TareasRadar)
        $pendientes = @($tareas | Where-Object { -not $_.Activa })
        $accion = 'Enable'
        if ($tareas.Count -gt 0 -and $pendientes.Count -eq 0) { $accion = 'Disable' }

        if (Invoke-AccionTareaElevada -Accion $accion) {
            Start-Sleep -Milliseconds 500
            & $script:RefrescarDashboard
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                'No se pudo cambiar el estado de las tareas (UAC cancelado o error).',
                'Radar', 'OK', 'Warning')
        }
    })

    $grid.Add_CellDoubleClick({
        param($origen, $e)
        if ($e.RowIndex -lt 0) { return }
        $ruta = $origen.Rows[$e.RowIndex].Tag
        if ($ruta) { Open-Informe -Ruta $ruta }
    })

    $grid.Add_KeyDown({
        param($origen, $e)
        if ($e.KeyCode -eq 'Return' -and $origen.SelectedRows.Count -gt 0) {
            $ruta = $origen.SelectedRows[0].Tag
            if ($ruta) { Open-Informe -Ruta $ruta }
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 20000
    $timer.Add_Tick($refrescar)
    $script:TimerDashboard = $timer
    $form.Add_Shown({
        & $script:RefrescarDashboard
        $script:TimerDashboard.Start()
    })
    $form.Add_FormClosed({
        $script:TimerDashboard.Stop()
        $script:TimerDashboard.Dispose()
    })

    return $form
}

function Show-Dashboard {
    if ($script:UiForm -and -not $script:UiForm.IsDisposed -and $script:UiForm.Visible) {
        [void]$script:UiForm.Activate()
        return
    }

    $form = New-Dashboard
    [void]$form.ShowDialog()
    $form.Dispose()
    $script:UiForm = $null
    $script:UiGrid = $null
    $script:UiEstado = $null
    $script:UiBotonAlternar = $null
}

# ---------------------------------------------------------
# Icono del tray
# ---------------------------------------------------------
function Update-Icono {
    if (-not $script:Icono) { return }

    $ultimos = @(Read-InformesRadar -Maximo 1)
    if ($ultimos.Count -eq 0) {
        $script:Icono.Text = 'Radar: sin informes'
        return
    }

    $u = $ultimos[0]
    $txt = "Radar: $($u.Criticos) crit, $($u.Avisos) avisos - $($u.Fecha.ToString('dd/MM HH:mm'))"
    if ($txt.Length -gt 63) { $txt = $txt.Substring(0, 63) }
    $script:Icono.Text = $txt

    if ($script:UltimoVisto -and $u.Archivo -ne $script:UltimoVisto -and $u.Criticos -gt 0) {
        $script:Icono.ShowBalloonTip(
            10000,
            'Radar de Seguridad',
            "$($u.Criticos) criticos en la ultima corrida. Click para abrir el dashboard.",
            [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    $script:UltimoVisto = $u.Archivo
}

function Start-Tray {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $icono = New-Object System.Windows.Forms.NotifyIcon
    $icono.Icon = [System.Drawing.SystemIcons]::Shield
    $icono.Text = 'Radar de Seguridad'

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $itemAbrir = $menu.Items.Add('Abrir dashboard')
    $itemAbrir.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $itemAbrir.Add_Click({ Show-Dashboard })

    [void]$menu.Items.Add('-')

    $itemCorrer = $menu.Items.Add('Correr radar ahora')
    $itemCorrer.Add_Click({
        if (Invoke-AccionTareaElevada -Accion 'Run') {
            Start-Sleep -Milliseconds 800
            Update-Icono
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                'No se pudo iniciar la corrida (UAC cancelado o error).',
                'Radar', 'OK', 'Warning')
        }
    })

    $itemAlternar = $menu.Items.Add('Pausar radar')
    $script:UiItemAlternar = $itemAlternar
    $itemAlternar.Add_Click({
        $tareas = @(Get-TareasRadar)
        $pendientes = @($tareas | Where-Object { -not $_.Activa })
        $accion = 'Enable'
        if ($tareas.Count -gt 0 -and $pendientes.Count -eq 0) { $accion = 'Disable' }

        if (Invoke-AccionTareaElevada -Accion $accion) {
            Start-Sleep -Milliseconds 500
            Update-EstadoRadar
            Update-Icono
        }
    })

    $itemCarpeta = $menu.Items.Add('Abrir carpeta de informes')
    $itemCarpeta.Add_Click({
        if (Test-Path -LiteralPath $script:dirLogs) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:dirLogs)`""
        }
    })

    [void]$menu.Items.Add('-')

    $itemSalir = $menu.Items.Add('Salir')
    $itemSalir.Add_Click({
        if ($script:Icono) {
            $script:Icono.Visible = $false
            $script:Icono.Dispose()
            $script:Icono = $null
        }
        [System.Windows.Forms.Application]::Exit()
    })

    $menu.Add_Opening({ Update-EstadoRadar })

    $icono.ContextMenuStrip = $menu
    $icono.Add_MouseClick({
        param($origen, $e)
        if ($origen -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Dashboard }
    })

    $icono.Visible = $true
    $script:Icono = $icono

    Update-Icono

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 60000
    $timer.Add_Tick({ Update-Icono })
    $timer.Start()
}

# ---------------------------------------------------------
# Modo accion elevada (lo invoca el propio script con UAC)
# ---------------------------------------------------------
if ($AccionTarea) {
    $tareas = @(Get-TareasRadar)
    if ($tareas.Count -eq 0) {
        Write-Output "No hay tareas del radar para la accion '$AccionTarea'."
        exit 1
    }

    $fallas = 0
    foreach ($t in $tareas) {
        try {
            switch ($AccionTarea) {
                'Disable' { Disable-ScheduledTask -TaskName $t.Nombre -ErrorAction Stop | Out-Null }
                'Enable' { Enable-ScheduledTask -TaskName $t.Nombre -ErrorAction Stop | Out-Null }
                'Run' { Start-ScheduledTask -TaskName $t.Nombre -ErrorAction Stop }
            }
        } catch {
            $fallas++
            Write-Output ("No se pudo aplicar '{0}' a {1}: {2}" -f $AccionTarea, $t.Nombre, $_.Exception.Message)
        }
    }

    if ($fallas -gt 0) { exit 1 }
    exit 0
}

# ---------------------------------------------------------
# Instancia unica
# ---------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, $script:MutexNombre)
$tengoMutex = $false
try {
    $tengoMutex = $mutex.WaitOne(0)
} catch {
    $tengoMutex = $false
}

if (-not $tengoMutex) {
    # Ya hay un icono corriendo: si se pidio, abrir el dashboard de esa instancia
    # no es posible desde aca. Se avisa y se sale.
    Write-Output 'El dashboard del radar ya esta corriendo.'
    exit 0
}

try {
    if (-not $SinIcono) { Start-Tray }
    if ($Mostrar -or $SinIcono) { Show-Dashboard }
    if (-not $SinIcono) { [System.Windows.Forms.Application]::Run() }
} finally {
    if ($script:Icono) {
        $script:Icono.Visible = $false
        $script:Icono.Dispose()
    }
    try { $mutex.ReleaseMutex() } catch { Write-Verbose 'Mutex no adquirido.' }
    $mutex.Dispose()
}
