# ==========================================
# SCRIPT: Radar de Seguridad Diario  (fase 1)
# Chequeos: SSH, puertos expuestos, tareas nuevas,
#           Defender, Firewall, RDP/WinRM, Identidad
#
# Uso:
#   .\Check-Port22.ps1                  # corrida normal
#   .\Check-Port22.ps1 -SinPopup        # prueba: no muestra popup
#   .\Check-Port22.ps1 -AbrirUltimo     # abre el ultimo informe de logs\ y sale
#   .\Check-Port22.ps1 -AprobarBaselines # acepta TODAS las novedades como conocidas
#   .\Check-Port22.ps1 -AprobarTareas    # solo tareas programadas
# ==========================================

param(
    [switch]$AprobarTareas,
    [switch]$AprobarBaselines,
    [switch]$SinPopup,
    [switch]$AbrirUltimo
)

$eventoLog      = "Seguridad-Port22"
$logType        = "Application"
$script:baseDir = Join-Path $PSScriptRoot "baseline"
$script:logsDir = Join-Path $PSScriptRoot "logs"
$refTareasTxt   = Join-Path $PSScriptRoot "tareas_baseline.txt"

$script:AprobarTodo   = [bool]$AprobarBaselines
$script:AprobarTareas = ([bool]$AprobarTareas -or [bool]$AprobarBaselines)

# ---------------------------------------------------------
# Configuracion (Radar.config.psd1) con defaults
# ---------------------------------------------------------
$config = @{
    PopupSoloCritico = $true
    # Cuantos informes .log se conservan SIN comprimir en logs\ (0 = todos).
    # Los mas viejos se archivan en logs\archivo\radar-<AAAA-MM>.zip (no se borran).
    RetencionInformes = 60

    # $true = los informes viejos se comprimen y se guardan para siempre.
    # $false = comportamiento viejo: los informes viejos se borran.
    ArchivarInformes = $true
    # Programa con el que se abre el informe desde el popup.
    # 'notepad.exe' = Notepad (siempre disponible, recomendado)
    # ''            = aplicacion asociada de Windows (puede no existir para .log)
    # 'code.cmd'    = VS Code, si esta en el PATH
    AbrirDetalleCon = 'notepad.exe'
    Umbrales = @{
        DiasFirmaDefender = 4
    }
    Aceptados = @{
        RDP   = $false
        WinRM = $false
    }
    ProcesosPermitidos = @(
        'svchost','lsass','System','smss','csrss','services','wininit','winlogon',
        'dwm','RuntimeBroker','SearchIndexer','MsMpEng','NisSrv','vmms'
    )
    Ignorar = @{
        # Patrones con comodines sobre Name o DisplayName de la regla
        ReglasFirewall = @()
        # Patrones con comodines sobre el TaskPath
        TareasPath     = @('\SoftLanding\*')
    }
}

$configPath = Join-Path $PSScriptRoot "Radar.config.psd1"
if (Test-Path $configPath) {
    try {
        $cfg = Import-PowerShellDataFile -Path $configPath
        foreach ($k in $cfg.Keys) {
            if ($k -in @('Umbrales','Aceptados','Ignorar')) {
                foreach ($kk in $cfg[$k].Keys) { $config[$k][$kk] = $cfg[$k][$kk] }
            } else {
                $config[$k] = $cfg[$k]
            }
        }
    } catch {
        Write-Warning "Radar.config.psd1 invalido, se usan los valores por defecto: $($_.Exception.Message)"
    }
}
$script:Config = $config

# Elevacion: los chequeos con linea base solo corren elevados, porque la vista
# del sistema cambia segun el privilegio (ej: Get-ScheduledTask ve 193 tareas
# sin admin y 262 con admin). La tarea programada corre con RunLevel Highest.
$script:EsAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------
# Helpers
# ---------------------------------------------------------
function New-Hallazgo {
    param(
        [ValidateSet('Critico','Aviso','Info')][string]$Severidad,
        [string]$Area,
        [string]$Detalle
    )
    [pscustomobject]@{ Severidad = $Severidad; Area = $Area; Detalle = $Detalle }
}

# Normaliza identificadores volatiles: GUIDs y numeros largos que los
# instaladores (Edge, Windows Update) regeneran en cada actualizacion.
# Sin esto, cada update parece "regla/tarea nueva" y genera falsos criticos.
function ConvertTo-ClaveEstable {
    param([string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return '' }

    # GUID con o sin llaves: HNS (Hyper-V / WSL) los usa sin llaves.
    $t = $Texto -replace '\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?', '{GUID}'
    # Contador que HNS agrega detras del GUID: "HNS ... - {GUID} - 0".
    $t = $t -replace '(\{GUID\}\s*-\s*)\d+$', '${1}<ID>'
    $t = $t -replace '\d{12,}', '<ID>'
    return $t
}

# Compara valores contra patrones con comodines (* y ?).
function Test-Ignorado {
    param([string[]]$Valores, [string[]]$Patrones)

    foreach ($p in @($Patrones)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        foreach ($v in @($Valores)) {
            if ([string]::IsNullOrWhiteSpace($v)) { continue }
            if ($v -like $p) { return $true }
        }
    }
    return $false
}

function Initialize-BaseDir {
    if (-not (Test-Path $script:baseDir)) {
        try { New-Item -ItemType Directory -Path $script:baseDir -Force | Out-Null }
        catch { Write-Warning "No se pudo crear $script:baseDir : $($_.Exception.Message)" }
    }
}

function Read-Baseline {
    param([string]$Nombre)
    $f = Join-Path $script:baseDir "$Nombre.json"

    # Devuelve un objeto siempre (nunca un array suelto): evita que PowerShell
    # "desenrolle" arreglos vacios o de un solo elemento al asignarlos.
    if (-not (Test-Path $f)) {
        return [pscustomobject]@{ Ok = $false; Items = @() }
    }

    try {
        $o = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @($o.items | Where-Object { $null -ne $_ })
        return [pscustomobject]@{ Ok = $true; Items = $items }
    } catch {
        Write-Warning "Baseline '$Nombre' ilegible; se regenera."
        return [pscustomobject]@{ Ok = $false; Items = @() }
    }
}

function Write-Baseline {
    param([string]$Nombre, [string[]]$Items)
    $f = Join-Path $script:baseDir "$Nombre.json"
    try {
        @{ items = @($Items | Sort-Object -Unique) } | ConvertTo-Json -Depth 5 |
            Set-Content -Path $f -Encoding UTF8
    } catch {
        Write-Warning "No se pudo guardar la baseline '$Nombre': $($_.Exception.Message)"
    }
}

function Compare-ConBaseline {
    param(
        [string]$Nombre,
        [string[]]$Actual,
        [switch]$Aprobar
    )
    $actualOrdenado = @($Actual | Sort-Object -Unique)

    $lectura = Read-Baseline -Nombre $Nombre
    if (-not $lectura.Ok) {
        Write-Baseline -Nombre $Nombre -Items $actualOrdenado
        return [pscustomobject]@{ Nuevos = @(); Primera = $true; Aprobado = $false }
    }

    $previos = @($lectura.Items)
    $nuevos = @(Compare-Object -ReferenceObject $previos -DifferenceObject $actualOrdenado -ErrorAction Stop |
        Where-Object { $_.SideIndicator -eq '=>' } |
        Select-Object -ExpandProperty InputObject)

    $aprobado = $false
    if ($Aprobar) {
        $aprobado = $true
        Write-Baseline -Nombre $Nombre -Items $actualOrdenado
    } elseif ($nuevos.Count -eq 0) {
        Write-Baseline -Nombre $Nombre -Items $actualOrdenado
    }

    return [pscustomobject]@{ Nuevos = $nuevos; Primera = $false; Aprobado = $aprobado }
}

function Write-LogSeguridad {
    param([string]$Mensaje, [string]$Tipo = 'Information', [int]$Id = 1000)
    try {
        Write-EventLog -LogName $logType -Source $eventoLog -EventId $Id `
            -EntryType $Tipo -Message $Mensaje -ErrorAction Stop
    } catch {
        Write-Warning "No se pudo escribir en el Event Log: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------
# Informe de ejecucion en archivo (para no abrir el Visor de Eventos)
# ---------------------------------------------------------
function Add-InformeAlArchivo {
    param(
        [string]$Ruta,
        [string]$DirArchivo
    )

    if (-not (Test-Path -LiteralPath $Ruta)) { return $null }
    if (-not (Test-Path -LiteralPath $DirArchivo)) {
        New-Item -ItemType Directory -Path $DirArchivo -Force | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $mes = (Get-Item -LiteralPath $Ruta).LastWriteTime.ToString('yyyy-MM')
    $rutaZip = Join-Path $DirArchivo "radar-$mes.zip"
    $nombre = Split-Path $Ruta -Leaf

    $zip = $null
    try {
        # Se pasan los modos como texto: los enums viven en otra assembly y
        # el literal [System.IO.Compression.ZipArchiveMode] no resuelve siempre.
        $existe = Test-Path -LiteralPath $rutaZip
        if ($existe) {
            $zip = [System.IO.Compression.ZipFile]::Open($rutaZip, 'Update')
        } else {
            $zip = [System.IO.Compression.ZipFile]::Open($rutaZip, 'Create')
        }

        # Nombre unico dentro del zip (por si se restauro un backup).
        # En modo Create no se puede enumerar: un zip nuevo no tiene duplicados.
        $entrada = $nombre
        if ($existe) {
            $n = 1
            while ($zip.GetEntry($entrada)) {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($nombre)
                $entrada = "$base-r$n.log"
                $n++
            }
        }

        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $Ruta, $entrada, 'Optimal')
        return $rutaZip
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Write-InformeEjecucion {
    param(
        [string]$Mensaje = '',
        [int]$EventId = 1000,
        [string]$TipoEvento = 'Information',
        [string]$Resumen = '',
        $Hallazgos = @(),
        [string]$Directorio = $script:logsDir
    )

    if ([string]::IsNullOrWhiteSpace($Directorio)) {
        $Directorio = Join-Path $PSScriptRoot 'logs'
    }

    try {
        if (-not (Test-Path $Directorio)) {
            New-Item -ItemType Directory -Path $Directorio -Force | Out-Null
        }

        $ahora = Get-Date
        $marca = $ahora.ToString('yyyyMMdd-HHmmss')
        $ruta = Join-Path $Directorio "radar-$marca.log"
        $n = 1
        while (Test-Path $ruta) {
            $ruta = Join-Path $Directorio "radar-$marca-$n.log"
            $n++
        }

        $sep = '=' * 66
        $lineas = @()
        $lineas += $sep
        $lineas += ' RADAR DE SEGURIDAD - INFORME DE EJECUCION'
        $lineas += $sep
        $lineas += "Fecha     : $($ahora.ToString('dd/MM/yyyy HH:mm:ss'))"
        $lineas += "Equipo    : $env:COMPUTERNAME"
        $lineas += "Usuario   : $env:USERNAME"
        $elevado = 'No'
        if ($script:EsAdmin) { $elevado = 'Si' }
        $lineas += "Elevado   : $elevado"
        $lineas += "Evento    : $logType / $eventoLog / ID $EventId ($TipoEvento)"
        if ($Resumen) { $lineas += "Resultado : $Resumen" }
        $lineas += ''

        $grupos = @(
            @{ Nombre = 'CRITICOS';    Severidad = 'Critico' },
            @{ Nombre = 'AVISOS';      Severidad = 'Aviso' },
            @{ Nombre = 'INFORMATIVOS'; Severidad = 'Info' }
        )
        foreach ($g in $grupos) {
            $items = @($Hallazgos | Where-Object { $_.Severidad -eq $g.Severidad })
            if ($items.Count -eq 0) { continue }
            $lineas += "$($g.Nombre) ($($items.Count))"
            foreach ($h in $items) { $lineas += "  - $($h.Area): $($h.Detalle)" }
            $lineas += ''
        }

        if (-not ($Hallazgos | Where-Object { $_.Severidad -ne 'Info' })) {
            $lineas += 'Sin hallazgos: el equipo mantiene la configuracion esperada.'
            $lineas += ''
        }

        $lineas += $sep
        $lineas += 'Mensaje registrado en el Event Log:'
        $lineas += $sep
        foreach ($l in ($Mensaje -split "`r?`n")) { $lineas += $l }
        $lineas += ''
        $lineas += $sep
        $lineas += 'Para aceptar las novedades como conocidas:'
        $lineas += '  .\Check-Port22.ps1 -AprobarBaselines'
        $lineas += '  .\Check-Port22.ps1 -AprobarTareas     (solo tareas programadas)'
        $lineas += $sep

        [System.IO.File]::WriteAllLines($ruta, [string[]]$lineas, (New-Object System.Text.UTF8Encoding($false)))

        # Retencion: conserva los N informes mas recientes sin comprimir.
        # Los anteriores NO se borran: se archivan en logs\archivo\radar-<AAAA-MM>.zip
        $retencion = 60
        if ($script:Config -and $script:Config.ContainsKey('RetencionInformes')) {
            $retencion = [int]$script:Config.RetencionInformes
        }
        $archivar = $true
        if ($script:Config -and $script:Config.ContainsKey('ArchivarInformes')) {
            $archivar = [bool]$script:Config.ArchivarInformes
        }

        if ($retencion -gt 0) {
            $dirArchivo = Join-Path $Directorio 'archivo'
            $viejos = @(Get-ChildItem -Path $Directorio -Filter 'radar-*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -Skip $retencion)

            foreach ($v in $viejos) {
                if ($archivar) {
                    try {
                        [void](Add-InformeAlArchivo -Ruta $v.FullName -DirArchivo $dirArchivo)
                        Remove-Item -LiteralPath $v.FullName -Force -ErrorAction SilentlyContinue
                    } catch {
                        # Si no se pudo archivar, se deja el archivo (nunca se pierde).
                        Write-Warning "No se pudo archivar $($v.Name): $($_.Exception.Message)"
                    }
                } else {
                    Remove-Item -LiteralPath $v.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }

        return $ruta
    } catch {
        Write-Warning "No se pudo escribir el informe de ejecucion: $($_.Exception.Message)"
        return $null
    }
}

# Abre el informe con la aplicacion asociada. Se usa explorer.exe a proposito:
# hereda la sesion del usuario y NO la elevacion, asi el visor no corre como admin.
function Open-InformeRadar {
    param([string]$Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta) -or -not (Test-Path $Ruta)) {
        Write-Warning "El informe no existe: $Ruta"
        return
    }

    $exe = ''
    if ($script:Config -and $script:Config.ContainsKey('AbrirDetalleCon')) {
        $exe = [string]$script:Config.AbrirDetalleCon
    }

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
# Popup con el detalle y un link al informe completo
# ---------------------------------------------------------
function Show-PopupRadar {
    param(
        [string]$Titulo = 'RADAR DE SEGURIDAD',
        [string]$Texto = '',
        [string]$RutaInforme = ''
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        Write-Warning "No se pudo cargar WinForms: $($_.Exception.Message)"
        return
    }

    $hayInforme = (-not [string]::IsNullOrWhiteSpace($RutaInforme)) -and (Test-Path $RutaInforme)

    # Coordenadas precalculadas: dentro de un New-Object(...) no se puede
    # usar aritmetica sin parentesis (PowerShell la parsea como argumento suelto).
    $anchoForm = 700
    $altoForm = 490
    $xLink = 86
    $anchoLink = 372
    $yLink = 434
    $yBotones = 429
    $xBotones = 470

    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Titulo
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ShowInTaskbar = $true
        $form.TopMost = $true
        $form.ClientSize = New-Object System.Drawing.Size($anchoForm, $altoForm)
        $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $lblTitulo = New-Object System.Windows.Forms.Label
        $lblTitulo.Text = $Titulo
        $lblTitulo.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        $lblTitulo.ForeColor = [System.Drawing.Color]::FromArgb(160, 20, 20)
        $lblTitulo.AutoSize = $true
        $lblTitulo.Location = New-Object System.Drawing.Point(16, 12)
        $form.Controls.Add($lblTitulo)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Multiline = $true
        $txt.ReadOnly = $true
        $txt.ScrollBars = 'Both'
        $txt.WordWrap = $false
        $txt.BackColor = [System.Drawing.Color]::White
        $txt.Font = New-Object System.Drawing.Font('Consolas', 9)
        $txt.Location = New-Object System.Drawing.Point(16, 42)
        $txt.Size = New-Object System.Drawing.Size(668, 380)
        $txt.Text = ($Texto -replace "`r?`n", "`r`n")
        $form.Controls.Add($txt)

        if ($hayInforme) {
            $script:RutaInformePopup = $RutaInforme

            # Etiqueta corta a la izquierda y el PATH como link clickeable.
            $lblInforme = New-Object System.Windows.Forms.Label
            $lblInforme.Text = 'Informe:'
            $lblInforme.AutoSize = $true
            $lblInforme.ForeColor = [System.Drawing.Color]::DimGray
            $lblInforme.Location = New-Object System.Drawing.Point(16, $yLink)
            $form.Controls.Add($lblInforme)

            $lnk = New-Object System.Windows.Forms.LinkLabel
            $lnk.Text = $RutaInforme
            $lnk.Location = New-Object System.Drawing.Point($xLink, $yLink)
            $lnk.Size = New-Object System.Drawing.Size($anchoLink, 18)
            $lnk.AutoEllipsis = $true
            $lnk.LinkColor = [System.Drawing.Color]::FromArgb(0, 90, 200)
            $lnk.ActiveLinkColor = [System.Drawing.Color]::FromArgb(200, 60, 0)
            $lnk.Add_LinkClicked({ Open-InformeRadar -Ruta $script:RutaInformePopup })

            $tip = New-Object System.Windows.Forms.ToolTip
            $tip.SetToolTip($lnk, "Click para abrir:`n$RutaInforme")
            $form.Controls.Add($lnk)
        } else {
            $lblSin = New-Object System.Windows.Forms.Label
            $lblSin.Text = 'Sin informe en archivo para esta corrida.'
            $lblSin.AutoSize = $true
            $lblSin.ForeColor = [System.Drawing.Color]::DimGray
            $lblSin.Location = New-Object System.Drawing.Point(16, $yLink)
            $form.Controls.Add($lblSin)
        }

        $btnCopiar = New-Object System.Windows.Forms.Button
        $btnCopiar.Text = 'Copiar'
        $btnCopiar.Size = New-Object System.Drawing.Size(90, 30)
        $btnCopiar.Location = New-Object System.Drawing.Point($xBotones, $yBotones)
        $btnCopiar.Add_Click({
            try {
                [System.Windows.Forms.Clipboard]::SetText($txt.Text)
            } catch {
                Write-Warning "No se pudo copiar al portapapeles: $($_.Exception.Message)"
            }
        })
        $form.Controls.Add($btnCopiar)

        $xCopiar = $xBotones
        $xCerrar = $xCopiar + 100
        $btnCerrar = New-Object System.Windows.Forms.Button
        $btnCerrar.Text = 'Cerrar'
        $btnCerrar.Size = New-Object System.Drawing.Size(90, 30)
        $btnCerrar.Location = New-Object System.Drawing.Point($xCerrar, $yBotones)
        $btnCerrar.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.AcceptButton = $btnCerrar
        $form.CancelButton = $btnCerrar
        $form.Controls.Add($btnCerrar)

        $form.Add_Shown({ $form.Activate() })
        [void]$form.ShowDialog()
        $form.Dispose()
    } catch {
        # Si WinForms falla, siempre queda el aviso clasico.
        Write-Warning "No se pudo mostrar la ventana con link: $($_.Exception.Message)"
        try {
            [System.Windows.Forms.MessageBox]::Show(
                $Texto + "`n`nInforme: $RutaInforme",
                $Titulo,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } catch {
            Write-Output "$Titulo`n$Texto"
        }
    }
}

# ---------------------------------------------------------
# Chequeos
# ---------------------------------------------------------
function Test-PuertoSSH {
    $out = @()

    $ssh = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    if ($ssh) {
        $pids = (@($ssh) | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
        $out += New-Hallazgo 'Critico' 'SSH' "Puerto 22 ABIERTO y escuchando (PID: $pids)"
    }

    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($svc) {
        $out += New-Hallazgo 'Aviso' 'SSH' "Servicio sshd instalado (estado: $($svc.Status)). Puede abrir el puerto 22."
    }

    return $out
}

function Test-PuertosExpuestos {
    $out = @()

    $lista = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('0.0.0.0','::') } |
        ForEach-Object {
            $proc   = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            $nombre = if ($proc) { $proc.Name } else { 'desconocido' }
            [pscustomobject]@{ Puerto = $_.LocalPort; Proceso = $nombre }
        } |
        Where-Object { $script:Config.ProcesosPermitidos -notcontains $_.Proceso } |
        Sort-Object Puerto -Unique

    if ($lista) {
        $detalle = (@($lista) | ForEach-Object { "$($_.Puerto) ($($_.Proceso))" }) -join ', '
        $out += New-Hallazgo 'Aviso' 'Puertos' "Escuchando en la red por procesos no habituales: $detalle"
    }

    return $out
}

function Test-TareasProgramadas {
    $out = @()

    if (-not $script:EsAdmin) { return $out }

    $ignorarPath = @($script:Config.Ignorar.TareasPath)

    # La clave se normaliza (GUIDs/IDs -> marcadores) porque Windows Update y
    # algunos instaladores recrean la misma tarea con identificadores nuevos.
    $actuales = @(Get-ScheduledTask |
        Where-Object { -not (Test-Ignorado -Valores @("$($_.TaskPath)") -Patrones $ignorarPath) } |
        ForEach-Object { ConvertTo-ClaveEstable -Texto "$($_.TaskPath)$($_.TaskName)" } |
        Sort-Object -Unique)

    # Migracion: si existe la baseline vieja en texto, se importa una vez
    $jsonTareas = Join-Path $script:baseDir 'tareas.json'
    if (-not (Test-Path $jsonTareas) -and (Test-Path $refTareasTxt)) {
        $previas = @(Get-Content $refTareasTxt |
            Where-Object { $_.Trim() } |
            ForEach-Object { ConvertTo-ClaveEstable -Texto $_.Trim() } |
            Sort-Object -Unique)
        if ($previas.Count -gt 0) {
            Write-Baseline -Nombre 'tareas' -Items $previas
            $out += New-Hallazgo 'Info' 'Tareas' "Linea base migrada desde tareas_baseline.txt ($($previas.Count) tareas)."
        }
    }

    $cmp = Compare-ConBaseline -Nombre 'tareas' -Actual $actuales -Aprobar:$script:AprobarTareas

    if ($cmp.Primera) {
        $out += New-Hallazgo 'Info' 'Tareas' "Linea base creada ($($actuales.Count) tareas)."
    } elseif ($cmp.Aprobado) {
        if ($cmp.Nuevos.Count -gt 0) {
            $out += New-Hallazgo 'Info' 'Tareas' "$($cmp.Nuevos.Count) tareas nuevas aceptadas en la linea base."
        }
    } elseif ($cmp.Nuevos.Count -gt 0) {
        $nombres = (@($cmp.Nuevos) | Sort-Object) -join '; '
        $out += New-Hallazgo 'Aviso' 'Tareas' "Tareas programadas nuevas: $nombres"
    }

    return $out
}

function Test-Defender {
    $out = @()

    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $mp) {
        $out += New-Hallazgo 'Aviso' 'Defender' 'No se pudo leer el estado de Microsoft Defender (posible antivirus de terceros o VM sin Defender).'
        return $out
    }

    $modo = "$($mp.AMRunningMode)"
    if (-not $mp.RealTimeProtectionEnabled) {
        if ($modo -match 'Passive') {
            $out += New-Hallazgo 'Aviso' 'Defender' "Defender en modo '$modo': hay otro antivirus activo."
        } else {
            $out += New-Hallazgo 'Critico' 'Defender' "Proteccion en tiempo real DESACTIVADA (modo: '$modo')."
        }
    }

    if (($mp.PSObject.Properties.Name -contains 'IsTamperProtected') -and (-not $mp.IsTamperProtected)) {
        $out += New-Hallazgo 'Aviso' 'Defender' 'Proteccion contra manipulacion (Tamper Protection) desactivada.'
    }

    $edad = [int]$mp.AntivirusSignatureAge
    if ($edad -gt [int]$script:Config.Umbrales.DiasFirmaDefender) {
        $out += New-Hallazgo 'Aviso' 'Defender' "Firmas con $edad dias de antiguedad (umbral: $($script:Config.Umbrales.DiasFirmaDefender))."
    }

    $activas = @()
    if ($script:EsAdmin) {
        $activas = @(Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { $_.IsActive })
    }
    if ($activas.Count -gt 0) {
        $nombres = (@($activas) | ForEach-Object { $_.ThreatName } | Select-Object -Unique) -join '; '
        $out += New-Hallazgo 'Critico' 'Defender' "Amenazas ACTIVAS detectadas: $nombres"
    }

    if ($script:EsAdmin) {
        $pref = Get-MpPreference -ErrorAction SilentlyContinue
        if ($pref) {
            $crudo = @(@($pref.ExclusionPath) + @($pref.ExclusionProcess) + @($pref.ExclusionExtension)) |
                Where-Object { $_ }

            $sinPermiso = @($crudo | Where-Object { "$_" -match 'Must be an administrator to view exclusions' })
            if ($sinPermiso.Count -gt 0) {
                $out += New-Hallazgo 'Info' 'Defender' 'Exclusiones no legibles sin permisos de Administrador; se omiten en esta corrida.'
            } else {
                $excl = @()
                foreach ($p in @($pref.ExclusionPath))      { if ($p) { $excl += "Ruta|$p" } }
                foreach ($p in @($pref.ExclusionProcess))   { if ($p) { $excl += "Proceso|$p" } }
                foreach ($p in @($pref.ExclusionExtension)) { if ($p) { $excl += "Extension|$p" } }

                $cmp = Compare-ConBaseline -Nombre 'defender-exclusiones' -Actual $excl -Aprobar:$script:AprobarTodo

                if ($cmp.Primera) {
                    $out += New-Hallazgo 'Info' 'Defender' "Linea base de exclusiones creada ($($excl.Count) entradas)."
                } elseif ($cmp.Aprobado) {
                    if ($cmp.Nuevos.Count -gt 0) {
                        $out += New-Hallazgo 'Info' 'Defender' "$($cmp.Nuevos.Count) exclusiones nuevas aceptadas en la linea base."
                    }
                } elseif ($cmp.Nuevos.Count -gt 0) {
                    $out += New-Hallazgo 'Critico' 'Defender' ("Exclusiones NUEVAS en Defender: " + ((@($cmp.Nuevos)) -join '; '))
                }
            }
        }
    }

    return $out
}

function Test-Firewall {
    $out = @()

    $perfiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    if ($perfiles.Count -eq 0) {
        $out += New-Hallazgo 'Aviso' 'Firewall' 'No se pudo leer el estado de los perfiles de firewall.'
    }

    foreach ($p in $perfiles) {
        if (-not $p.Enabled) {
            $out += New-Hallazgo 'Critico' 'Firewall' "Perfil '$($p.Name)' DESHABILITADO."
        }
        if ("$($p.DefaultInboundAction)" -eq 'Allow') {
            $out += New-Hallazgo 'Critico' 'Firewall' "Perfil '$($p.Name)': DefaultInboundAction = Allow (entradas permitidas por defecto)."
        }
    }

    if ($script:EsAdmin) {
        $ignorar = @($script:Config.Ignorar.ReglasFirewall)

        $permitidas = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue |
            Where-Object {
                # En el objeto de Get-NetFirewallRule, "Any" suele venir como cadena vacia
                $ra = ($_.RemoteAddress -join ',')
                $esAny = [string]::IsNullOrWhiteSpace($ra) -or ($ra -match 'Any')
                $esAny -and ("$($_.Profile)" -match 'Public|Any')
            } |
            ForEach-Object {
                $nombre  = "$($_.Name)"
                $mostrar = "$($_.DisplayName)"
                if ([string]::IsNullOrWhiteSpace($mostrar)) { $mostrar = $nombre }
                [pscustomobject]@{
                    Nombre  = $nombre
                    Mostrar = $mostrar
                    # Name estable: los GUIDs (Edge/Brave/Firefox, WebView2) cambian
                    # en cada actualizacion y no deben contar como regla nueva.
                    Texto   = "$(ConvertTo-ClaveEstable -Texto $nombre)|$mostrar|$($_.Profile)"
                }
            } |
            Where-Object { -not (Test-Ignorado -Valores @($_.Nombre, $_.Mostrar) -Patrones $ignorar) } |
            ForEach-Object { $_.Texto })

        $cmp = Compare-ConBaseline -Nombre 'firewall-reglas' -Actual $permitidas -Aprobar:$script:AprobarTodo

        if ($cmp.Primera) {
            $out += New-Hallazgo 'Info' 'Firewall' "Linea base de reglas de entrada creada ($($permitidas.Count) reglas)."
        } elseif ($cmp.Aprobado) {
            if ($cmp.Nuevos.Count -gt 0) {
                $out += New-Hallazgo 'Info' 'Firewall' "$($cmp.Nuevos.Count) reglas nuevas aceptadas en la linea base."
            }
        } elseif ($cmp.Nuevos.Count -gt 0) {
            $detalle = (@($cmp.Nuevos) | ForEach-Object { ($_ -split '\|', 2)[1] }) -join '; '
            $out += New-Hallazgo 'Critico' 'Firewall' "Reglas de entrada NUEVAS expuestas a redes publicas: $detalle"
        }
    }

    return $out
}

function Test-AccesoRemoto {
    $out = @()

    $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    if ($ts -and $ts.fDenyTSConnections -eq 0) {
        $severidad = if ($script:Config.Aceptados.RDP) { 'Info' } else { 'Critico' }
        $out += New-Hallazgo $severidad 'RDP' 'Escritorio Remoto HABILITADO (fDenyTSConnections = 0).'

        $rdp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue
        if ($rdp) {
            if ($rdp.UserAuthentication -eq 0) {
                $out += New-Hallazgo 'Aviso' 'RDP' 'NLA (Network Level Authentication) deshabilitado.'
            }
            if ($rdp.PortNumber -and $rdp.PortNumber -ne 3389) {
                $out += New-Hallazgo 'Aviso' 'RDP' "RDP configurado en puerto no estandar: $($rdp.PortNumber)."
            }
        }
    }

    # OJO: no usar el proveedor WSMan:\ aca. Al accederlo, PowerShell ofrece
    # INICIAR el servicio WinRM y, en la tarea oculta, queda esperando respuesta.
    $svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($svc) {
        $escucha = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -in @(5985, 5986) })

        if ($svc.Status -eq 'Running' -or $escucha.Count -gt 0) {
            $severidad = if ($script:Config.Aceptados.WinRM) { 'Info' } else { 'Critico' }
            $detalle = if ($svc.Status -eq 'Running') {
                'servicio corriendo'
            } else {
                $puertos = (@($escucha) | Select-Object -ExpandProperty LocalPort -Unique) -join ','
                "escuchando en $puertos"
            }
            $out += New-Hallazgo $severidad 'WinRM' "WinRM activo ($detalle): administracion remota expuesta en 5985/5986."
        } elseif ($svc.StartType -eq 'Automatic') {
            $out += New-Hallazgo 'Aviso' 'WinRM' 'WinRM con arranque automatico: se iniciara en el proximo reinicio.'
        }
    }

    return $out
}

function Test-Identidad {
    $out = @()

    # Administradores locales (por SID: funciona en Windows en espanol)
    if ($script:EsAdmin) {
        $admins = @(Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue |
            Get-LocalGroupMember -ErrorAction SilentlyContinue |
            ForEach-Object { "$($_.ObjectClass)|$($_.SID.Value)|$($_.Name)" })

        $cmp = Compare-ConBaseline -Nombre 'identidad-admins' -Actual $admins -Aprobar:$script:AprobarTodo
        if ($cmp.Primera) {
            $out += New-Hallazgo 'Info' 'Identidad' "Linea base de administradores creada ($($admins.Count) miembros)."
        } elseif ($cmp.Aprobado) {
            if ($cmp.Nuevos.Count -gt 0) {
                $out += New-Hallazgo 'Info' 'Identidad' "$($cmp.Nuevos.Count) cambios de administradores aceptados en la linea base."
            }
        } elseif ($cmp.Nuevos.Count -gt 0) {
            $nombres = (@($cmp.Nuevos) | ForEach-Object { ($_ -split '\|')[2] }) -join '; '
            $out += New-Hallazgo 'Critico' 'Identidad' "NUEVOS miembros en Administradores locales: $nombres"
        }
    }

    # Usuarios locales
    if ($script:EsAdmin) {
        $usuarios = @(Get-LocalUser -ErrorAction SilentlyContinue |
            ForEach-Object { "$($_.Name)|Enabled=$($_.Enabled)|PasswordRequired=$($_.PasswordRequired)" })

        $cmp = Compare-ConBaseline -Nombre 'identidad-usuarios' -Actual $usuarios -Aprobar:$script:AprobarTodo
        if ($cmp.Primera) {
            $out += New-Hallazgo 'Info' 'Identidad' "Linea base de usuarios locales creada ($($usuarios.Count) cuentas)."
        } elseif ($cmp.Aprobado) {
            if ($cmp.Nuevos.Count -gt 0) {
                $out += New-Hallazgo 'Info' 'Identidad' "$($cmp.Nuevos.Count) cambios de cuentas aceptados en la linea base."
            }
        } elseif ($cmp.Nuevos.Count -gt 0) {
            $nombres = (@($cmp.Nuevos) | ForEach-Object { ($_ -split '\|')[0] }) -join '; '
            $out += New-Hallazgo 'Critico' 'Identidad' "Cuentas locales NUEVAS o modificadas: $nombres"
        }
    }

    # Cuentas integradas
    $invitado = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -like '*-501' }
    if ($invitado -and $invitado.Enabled) {
        $out += New-Hallazgo 'Aviso' 'Identidad' "Cuenta Guest/Invitado HABILITADA ($($invitado.Name))."
    }

    $adminIntegrado = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -like '*-500' }
    if ($adminIntegrado -and $adminIntegrado.Enabled) {
        $out += New-Hallazgo 'Aviso' 'Identidad' "Cuenta Administrator integrada HABILITADA ($($adminIntegrado.Name))."
    }

    # Autologon con contrasena en texto plano
    $winlogon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if ($winlogon -and $winlogon.DefaultPassword) {
        $out += New-Hallazgo 'Critico' 'Identidad' 'Autologon con contrasena en texto plano en el registro (Winlogon\DefaultPassword).'
    }

    # UAC
    $lsaSystem = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    if ($lsaSystem -and $lsaSystem.EnableLUA -ne 1) {
        $out += New-Hallazgo 'Critico' 'Identidad' "UAC DESHABILITADO (EnableLUA = $($lsaSystem.EnableLUA))."
    }

    # WDigest: almacenamiento de credenciales en claro
    $wdigest = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name UseLogonCredential -ErrorAction SilentlyContinue
    if ($wdigest -and $wdigest.UseLogonCredential -eq 1) {
        $out += New-Hallazgo 'Critico' 'Identidad' 'WDigest con UseLogonCredential = 1 (credenciales recuperables desde memoria).'
    }

    return $out
}

# ---------------------------------------------------------
# Ejecucion
# ---------------------------------------------------------
# Atajo: abrir el ultimo informe guardado y salir sin correr chequeos.
if ($AbrirUltimo) {
    $ultimo = Get-ChildItem -Path $script:logsDir -Filter 'radar-*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $ultimo) {
        Write-Output "No hay informes en $script:logsDir. Corre el radar al menos una vez."
        return
    }
    Write-Output "Ultimo informe: $($ultimo.FullName)"
    Open-InformeRadar -Ruta $ultimo.FullName
    return
}

Initialize-BaseDir

if (-not $script:EsAdmin) {
    Write-Output "[i] Sin Administrador: se omiten los chequeos con linea base (tareas, exclusiones de Defender, reglas de firewall, identidad) y amenazas activas."
    Write-Output "    Para el chequeo completo: Start-ScheduledTask -TaskName 'Seguridad - Revision Puerto SSH' o PowerShell elevado."
}

$hallazgos = @()

$chequeos = @(
    @{ Nombre = 'SSH';       Funcion = { Test-PuertoSSH } },
    @{ Nombre = 'Puertos';   Funcion = { Test-PuertosExpuestos } },
    @{ Nombre = 'Tareas';    Funcion = { Test-TareasProgramadas } },
    @{ Nombre = 'Defender';  Funcion = { Test-Defender } },
    @{ Nombre = 'Firewall';  Funcion = { Test-Firewall } },
    @{ Nombre = 'RDP/WinRM'; Funcion = { Test-AccesoRemoto } },
    @{ Nombre = 'Identidad'; Funcion = { Test-Identidad } }
)

foreach ($c in $chequeos) {
    try {
        $hallazgos += & $c.Funcion
    } catch {
        $hallazgos += New-Hallazgo 'Aviso' $c.Nombre "No se pudo evaluar: $($_.Exception.Message)"
    }
}

$criticos = @($hallazgos | Where-Object { $_.Severidad -eq 'Critico' })
$avisos   = @($hallazgos | Where-Object { $_.Severidad -eq 'Aviso' })
$infos    = @($hallazgos | Where-Object { $_.Severidad -eq 'Info' })

foreach ($h in $infos)    { Write-Output "[i] $($h.Area): $($h.Detalle)" }
foreach ($h in $avisos)   { Write-Output "[!] $($h.Area): $($h.Detalle)" }
foreach ($h in $criticos) { Write-Output "[X] $($h.Area): $($h.Detalle)" }

# --- Event Log ---
$partes = @()
if ($criticos.Count -gt 0) {
    $partes += "CRITICOS ($($criticos.Count)):"
    $criticos | ForEach-Object { $partes += " - $($_.Area): $($_.Detalle)" }
}
if ($avisos.Count -gt 0) {
    $partes += "AVISOS ($($avisos.Count)):"
    $avisos | ForEach-Object { $partes += " - $($_.Area): $($_.Detalle)" }
}
if ($partes.Count -eq 0) { $partes = @('Radar OK: sin hallazgos.') }
$mensajeEvento = $partes -join "`n"

$eventId = 1000
$tipoEvento = 'Information'
if ($criticos.Count -gt 0) {
    $eventId = 1001
    $tipoEvento = 'Error'
} elseif ($avisos.Count -gt 0) {
    $eventId = 1002
    $tipoEvento = 'Warning'
}

# --- Informe en archivo (el popup lo abre con un click) ---
$resumen = "$($criticos.Count) criticos, $($avisos.Count) avisos, $($infos.Count) informativos"
$rutaInforme = Write-InformeEjecucion -Mensaje $mensajeEvento -EventId $eventId `
    -TipoEvento $tipoEvento -Resumen $resumen -Hallazgos $hallazgos

$mensajeConRuta = $mensajeEvento
if ($rutaInforme) { $mensajeConRuta += "`n`nInforme completo: $rutaInforme" }
Write-LogSeguridad -Mensaje $mensajeConRuta -Tipo $tipoEvento -Id $eventId

# --- Popup ---
$mostrarPopup = $false
if ($criticos.Count -gt 0) {
    $mostrarPopup = $true
} elseif ($avisos.Count -gt 0 -and -not $script:Config.PopupSoloCritico) {
    $mostrarPopup = $true
}
if ($SinPopup) { $mostrarPopup = $false }

if ($mostrarPopup) {
    $lineasPopup = @()
    if ($criticos.Count -gt 0) {
        $lineasPopup += "CRITICOS ($($criticos.Count)):"
        $criticos | ForEach-Object { $lineasPopup += " - $($_.Area): $($_.Detalle)" }
        $lineasPopup += ''
    }
    if ($avisos.Count -gt 0) {
        $lineasPopup += "AVISOS ($($avisos.Count)):"
        $avisos | ForEach-Object { $lineasPopup += " - $($_.Area): $($_.Detalle)" }
        $lineasPopup += ''
    }

    # Techo defensivo: el detalle completo queda en el archivo.
    if ($lineasPopup.Count -gt 300) {
        $resto = $lineasPopup.Count - 299
        $lineasPopup = @($lineasPopup[0..298]) + "... y $resto lineas mas (ver informe completo)"
    }

    $textoPopup = ($lineasPopup -join "`n") + "`nRevisar y actuar."
    Show-PopupRadar -Titulo 'RADAR DE SEGURIDAD' -Texto $textoPopup -RutaInforme $rutaInforme
}

# --- Consola ---
if ($criticos.Count -eq 0 -and $avisos.Count -eq 0) {
    Write-Output "RADAR OK: sin amenazas detectadas ($($infos.Count) informativos)."
} else {
    Write-Output "RADAR: $($criticos.Count) criticos, $($avisos.Count) avisos. Evento ID $eventId."
}
if ($rutaInforme) { Write-Output "Informe: $rutaInforme" }

