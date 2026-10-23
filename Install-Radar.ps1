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
$baseline   = Join-Path (Split-Path $ScriptPath -Parent) 'tareas_baseline.txt'

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

    Write-Host ""
    Write-Host "Los archivos NO se borraron. Para eliminarlos manualmente:" -ForegroundColor Gray
    Write-Host "  Remove-Item '$ScriptPath'" -ForegroundColor Gray
    Write-Host "  Remove-Item '$baseline'" -ForegroundColor Gray
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
Write-Ok "Linea base de tareas: $baseline"

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
    Write-Ok "La fuente '$source' ya existe. No se toca."
} else {
    New-EventLog -LogName Application -Source $source
    Write-Ok "Fuente '$source' creada en el log Application."
}

# ---------------------------------------------------------
# 3. Tarea programada
# ---------------------------------------------------------
Write-Step "3/5 - Tarea programada"

$argumentos = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
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
    -Description "Radar diario: puerto SSH 22, puertos expuestos y tareas programadas nuevas." `
    -Force | Out-Null

$tarea = Get-ScheduledTask -TaskName $TaskName
Write-Ok "Tarea '$TaskName' creada/reemplazada."
Write-Ok ("Triggers: {0} (diaria {1} + al iniciar sesion)" -f $tarea.Triggers.Count, $DailyAt)
Write-Ok ("RunLevel: {0}" -f $tarea.Principal.RunLevel)

# ---------------------------------------------------------
# 4. Primera ejecucion (crea la linea base)
# ---------------------------------------------------------
if ($NoFirstRun) {
    Write-Step "4/5 - Primera ejecucion OMITIDA (-NoFirstRun)"
    Write-Aviso "La linea base se creara en la proxima corrida programada."
} else {
    Write-Step "4/5 - Primera ejecucion"
    if (Test-Path -LiteralPath $baseline) {
        Write-Aviso "Ya existe la linea base; se conserva la actual."
    } else {
        Write-Aviso "Se creara la linea base con las tareas actuales (no alerta en esta corrida)."
    }
    & $ScriptPath
}

# ---------------------------------------------------------
# 5. Verificacion de punta a punta
# ---------------------------------------------------------
Write-Step "5/5 - Verificacion"

if ($NoFirstRun) {
    Write-Aviso "Verificacion de ejecucion omitida. Probar con: Start-ScheduledTask -TaskName '$TaskName'"
} else {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 5

    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    if ($info.LastTaskResult -eq 0) {
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
Write-Host "  Baseline : $baseline"
Write-Host ""
Write-Host "Comandos utiles:" -ForegroundColor Cyan
Write-Cmd "& '$ScriptPath'"                                          "correr el radar ahora"
Write-Cmd "& '$ScriptPath' -AprobarTareas"                           "aceptar tareas nuevas como conocidas"
Write-Cmd "Start-ScheduledTask -TaskName '$TaskName'"                "forzar la tarea"
Write-Cmd "Get-EventLog -LogName Application -Source '$source' -Newest 5"
Write-Cmd ".\Install-Radar.ps1 -Uninstall"                           "quitar tarea y fuente de log"
Write-Host ""
