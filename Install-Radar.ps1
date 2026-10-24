# ==========================================
# SCRIPT: Install-Radar.ps1
# Instalador todo-en-uno del Radar de Seguridad (Windows 11)
#
# Hace en un solo paso:
#   1. Verifica el script principal
#   2. Registra la fuente del Event Log
#   3. Crea/reemplaza la tarea programada
#   4. Corre la primera vez (crea la linea base)
#   5. Verifica que todo quedo operativo
#
# Uso:
#   .\Install-Radar.ps1
#   .\Install-Radar.ps1 -DailyAt "11:00PM"
#   .\Install-Radar.ps1 -NoFirstRun
#   .\Install-Radar.ps1 -Uninstall
#
# Se auto-eleva si no se ejecuta como Administrador.
# ==========================================

[CmdletBinding()]
param(
    [string]$ScriptPath,
    [string]$TaskName = "Seguridad - Revision Puerto SSH",
    [string]$DailyAt  = "12:00AM",
    [switch]$NoFirstRun,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$source = "Seguridad-Port22"

function Write-Step {
    param([string]$Texto)
    Write-Host ""
    Write-Host "== $Texto" -ForegroundColor Cyan
}
function Write-Ok {
    param([string]$Texto)
    Write-Host "   [OK] $Texto" -ForegroundColor Green
}
function Write-Aviso {
    param([string]$Texto)
    Write-Host "   [!]  $Texto" -ForegroundColor Yellow
}
function Write-Fail {
    param([string]$Texto)
    Write-Host "   [X]  $Texto" -ForegroundColor Red
}
function Write-Cmd {
    param([string]$Comando, [string]$Comentario = '')
    if ($Comentario) {
        Write-Host (("  " + $Comando).PadRight(66) + "# $Comentario")
    } else {
        Write-Host ("  " + $Comando)
    }
}

# ---------------------------------------------------------
# 0. Elevacion (necesaria para New-EventLog y Register-ScheduledTask)
# ---------------------------------------------------------
$identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
$esAdmin = (New-Object Security.Principal.WindowsPrincipal($identidad)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $esAdmin) {
    Write-Host "Se requieren permisos de Administrador. Reabriendo elevado..." -ForegroundColor Yellow

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($PSBoundParameters.ContainsKey('ScriptPath')) { $argList += @('-ScriptPath', ('"{0}"' -f $ScriptPath)) }
    if ($PSBoundParameters.ContainsKey('TaskName'))   { $argList += @('-TaskName',   ('"{0}"' -f $TaskName)) }
    if ($PSBoundParameters.ContainsKey('DailyAt'))    { $argList += @('-DailyAt',    ('"{0}"' -f $DailyAt)) }
    if ($NoFirstRun) { $argList += '-NoFirstRun' }
    if ($Uninstall)  { $argList += '-Uninstall' }

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList ($argList -join ' ') -Verb RunAs
    } catch {
        Write-Fail "No se pudo elevar. Abri PowerShell como Administrador y volve a ejecutar."
        exit 1
    }
    return
}

# ---------------------------------------------------------
# Rutas
# ---------------------------------------------------------
if (-not $ScriptPath) {
    $ScriptPath = Join-Path $PSScriptRoot 'Check-Port22.ps1'
}
$ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
$dirBase    = Join-Path (Split-Path $ScriptPath -Parent) 'baseline'
$configFile = Join-Path (Split-Path $ScriptPath -Parent) 'Radar.config.psd1'

# ---------------------------------------------------------
# Modo desinstalacion
# ---------------------------------------------------------
if ($Uninstall) {
    Write-Step "Desinstalando el Radar de Seguridad"

    $tarea = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($tarea) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Ok "Tarea '$TaskName' eliminada."
    } else {
        Write-Aviso "La tarea '$TaskName' no existia."
    }

    if ([System.Diagnostics.EventLog]::SourceExists($source)) {
        Remove-EventLog -Source $source
        Write-Ok "Fuente de Event Log '$source' eliminada (se borran sus eventos)."
    } else {
        Write-Aviso "La fuente '$source' no existia."
    }

    $dirBaseUninstall = Join-Path (Split-Path $ScriptPath -Parent) 'baseline'
    if (Test-Path -LiteralPath $dirBaseUninstall) {
        Remove-Item -LiteralPath $dirBaseUninstall -Recurse -Force
        Write-Ok "Lineas base eliminadas: $dirBaseUninstall"
    }
    $legacy = Join-Path (Split-Path $ScriptPath -Parent) 'tareas_baseline.txt'
    if (Test-Path -LiteralPath $legacy) {
        Remove-Item -LiteralPath $legacy -Force
        Write-Ok "Baseline legacy eliminada: $legacy"
    }

    Write-Host ""
    Write-Host "Los scripts y la configuracion NO se borraron. Para eliminarlos manualmente:" -ForegroundColor Gray
    Write-Host "  Remove-Item '$ScriptPath'" -ForegroundColor Gray
    Write-Host "  Remove-Item '$(Join-Path (Split-Path $ScriptPath -Parent) 'Install-Radar.ps1')'" -ForegroundColor Gray
    Write-Host "  Remove-Item '$(Join-Path (Split-Path $ScriptPath -Parent) 'Radar.config.psd1')'" -ForegroundColor Gray
    return
}

# ---------------------------------------------------------
# 1. Verificaciones previas
# ---------------------------------------------------------
Write-Step "1/5 - Verificando archivos"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Fail "No se encontro el script principal: $ScriptPath"
    Write-Host "   Descargalo junto a este instalador o usa: -ScriptPath 'C:\ruta\Check-Port22.ps1'" -ForegroundColor Gray
    exit 1
}
Write-Ok "Script principal: $ScriptPath"
Write-Ok "Linea base: $dirBase"

try {
    $triggerDiario = New-ScheduledTaskTrigger -Daily -At $DailyAt
} catch {
    Write-Fail "Hora invalida: '$DailyAt'. Usa formato 12:00AM / 09:30PM / 23:00."
    exit 1
}

# ---------------------------------------------------------
# 2. Fuente del Event Log
# ---------------------------------------------------------
Write-Step "2/5 - Fuente del Event Log"

if ([System.Diagnostics.EventLog]::SourceExists($source)) {
    $logActual = ''
    try { $logActual = [System.Diagnostics.EventLog]::LogNameFromSourceName($source, '.') }
    catch { $logActual = '' }
    if ($logActual -eq 'Application') {
        Write-Ok "La fuente '$source' ya existe en Application. No se toca."
    } else {
        Write-Fail "La fuente '$source' existe pero en el log '$logActual', no en Application."
        Write-Host "   Resolver a mano: Remove-EventLog -Source '$source' y volver a ejecutar." -ForegroundColor Gray
        exit 1
    }
} else {
    New-EventLog -LogName Application -Source $source
    Write-Ok "Fuente '$source' creada en el log Application."
}

# ---------------------------------------------------------
# 3. Tarea programada
# ---------------------------------------------------------
Write-Step "3/5 - Tarea programada"

# Estado previo: si estaba pausada, se respeta; si estaba corriendo, se detiene
$tareaPrevia = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$pausada = [bool]($tareaPrevia -and $tareaPrevia.State -eq 'Disabled')
if ($pausada) {
    Write-Aviso "La tarea estaba PAUSADA: se reinstala y se deja pausada."
}
if ($tareaPrevia -and $tareaPrevia.State -eq 'Running') {
    Write-Aviso "La tarea estaba corriendo: se detiene antes de reinstalar."
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Si quedo un proceso colgado (por ejemplo un prompt sin consola), matarlo
    if ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running') {
        Write-Aviso "Sigue en ejecucion: terminando el proceso del radar."
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$ScriptPath*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
}

$argumentos = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument $argumentos
$triggers = @(
    $triggerDiario,
    (New-ScheduledTaskTrigger -AtLogOn)
)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 60)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $triggers `
    -Settings $settings `
    -User "$env:USERDOMAIN\$env:USERNAME" `
    -RunLevel Highest `
    -Description "Radar diario: SSH, puertos, tareas, Defender, firewall, RDP/WinRM e identidad." `
    -Force | Out-Null

$tarea = Get-ScheduledTask -TaskName $TaskName

if ($pausada) {
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Ok "Tarea '$TaskName' creada/reemplazada y dejada PAUSADA (como estaba)."
} else {
    Write-Ok "Tarea '$TaskName' creada/reemplazada."
}
Write-Ok ("Triggers: {0} (diaria {1} + al iniciar sesion)" -f $tarea.Triggers.Count, $DailyAt)
Write-Ok ("RunLevel: {0}" -f $tarea.Principal.RunLevel)

# ---------------------------------------------------------
# 4. Primera ejecucion (crea la linea base)
# ---------------------------------------------------------
if ($pausada) {
    Write-Step "4/5 - Primera ejecucion OMITIDA (la tarea esta pausada)"
    Write-Aviso "Para reanudar: Enable-ScheduledTask -TaskName '$TaskName'"
} elseif ($NoFirstRun) {
    Write-Step "4/5 - Primera ejecucion OMITIDA (-NoFirstRun)"
    Write-Aviso "La linea base se creara en la proxima corrida programada."
} else {
    Write-Step "4/5 - Primera ejecucion"
    $hayBaseline = (Test-Path -LiteralPath $dirBase) -and
        (@(Get-ChildItem -LiteralPath $dirBase -ErrorAction SilentlyContinue).Count -gt 0)
    if ($hayBaseline) {
        Write-Aviso "Ya existen lineas base; se conservan las actuales."
    } else {
        Write-Aviso "Se crearan las lineas base con el estado actual (no alerta en esta corrida)."
    }
    & $ScriptPath
}

# ---------------------------------------------------------
# 5. Verificacion de punta a punta
# ---------------------------------------------------------
Write-Step "5/5 - Verificacion"

if ($pausada) {
    Write-Step "5/5 - Verificacion OMITIDA (la tarea esta pausada)"
} elseif ($NoFirstRun) {
    Write-Aviso "Verificacion de ejecucion omitida. Probar con: Start-ScheduledTask -TaskName '$TaskName'"
} else {
    Start-ScheduledTask -TaskName $TaskName

    # Esperar a que termine (el radar puede tardar varios segundos)
    $limite = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Seconds 2
        $estado = (Get-ScheduledTask -TaskName $TaskName).State
    } while (($estado -eq 'Running' -or $estado -eq 'Queued') -and (Get-Date) -lt $limite)

    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    if ($estado -eq 'Running') {
        Write-Aviso "La tarea sigue corriendo despues de 90s. Revisar el Visor de Eventos."
    } elseif ($info.LastTaskResult -eq 0) {
        Write-Ok "La tarea corrio sin errores (LastTaskResult = 0)."
    } else {
        Write-Aviso "LastTaskResult = $($info.LastTaskResult). Revisar el Visor de Eventos."
    }
    Write-Ok ("Proxima ejecucion: {0}" -f $info.NextRunTime)
}

$ultimo = Get-EventLog -LogName Application -Source $source -Newest 1 -ErrorAction SilentlyContinue
if ($ultimo) {
    Write-Ok ("Ultimo evento: {0} | ID {1} | {2}" -f $ultimo.TimeGenerated, $ultimo.EventID, $ultimo.EntryType)
} else {
    Write-Aviso "Todavia no hay eventos registrados para '$source'."
}

# ---------------------------------------------------------
# Resumen
# ---------------------------------------------------------
Write-Host ""
Write-Host "Instalacion completa." -ForegroundColor Green
Write-Host "  Script   : $ScriptPath"
Write-Host "  Tarea    : $TaskName"
Write-Host "  Horario  : diaria $DailyAt + al iniciar sesion"
if ($pausada) {
    Write-Host "  Estado   : PAUSADA (reanudar con Enable-ScheduledTask -TaskName '$TaskName')" -ForegroundColor Yellow
}
Write-Host "  Baseline : $dirBase"
Write-Host "  Config   : $configFile"
Write-Host ""
Write-Host "Comandos utiles:" -ForegroundColor Cyan
Write-Cmd "& '$ScriptPath'"                                          "correr el radar ahora"
Write-Cmd "& '$ScriptPath' -AprobarBaselines"                        "aceptar novedades como conocidas"
Write-Cmd "& '$ScriptPath' -AprobarTareas"                           "aceptar solo tareas nuevas"
Write-Cmd "Start-ScheduledTask -TaskName '$TaskName'"                "forzar la tarea"
Write-Cmd "Get-EventLog -LogName Application -Source '$source' -Newest 5"
Write-Cmd ".\Install-Radar.ps1 -Uninstall"                           "quitar tarea, fuente y baselines"
Write-Host ""
